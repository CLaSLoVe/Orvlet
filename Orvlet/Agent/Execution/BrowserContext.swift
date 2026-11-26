import Foundation

@MainActor
extension AgentController {
    /// Check the intended text as well as the selector. Recover a stale/incorrect
    /// selector only when the exact value has one unambiguous observed match.
    func checkedPageReadings(_ readings: [CardReading], values: [String: String]?, observation: [String: Any]) throws -> [CardReading] {
        guard recovery.needsSourceReading || values != nil else { return readings }
        guard !readings.isEmpty else { throw ToolArgumentError(path: "$.readings", issue: "bind the requested source value before publishing") }
        let observed = observation["readables"] as? [[String: Any]] ?? []
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return try readings.map { reading in
            guard let expected = values?[reading.key], !normalized(expected).isEmpty else {
                throw ToolArgumentError(path: "$.readingValues", issue: "supply the exact observed text for every reading, including the requested measurement")
            }
            let matches = observed.filter { normalized($0["text"] as? String ?? "") == normalized(expected) }
            if matches.contains(where: { $0["selector"] as? String == reading.selector }) { return reading }
            guard matches.count == 1, let selector = matches.first?["selector"] as? String else {
                throw ToolArgumentError(path: "$.readingValues", issue: "the selected element does not uniquely report the intended value; use observe(query: the measurement label or value) to find it, then use the exact returned text and selector")
            }
            return CardReading(key: reading.key, selector: selector)
        }
    }

    func reusablePlan(_ observation: [String: Any]) -> SurfacePlan? {
        if model.hasCustomSurface, model.surface.markup != nil,
            let plan = try? model.surface.validated(observation: observation)
        {
            return plan
        }
        if let retained = model.browser.reusableMediaSurface(observation) { return retained }
        if let key = SurfaceCache.pageKey(observation["url"] as? String ?? ""),
            let cached = model.adaptive.cache.get(key), cached.markup?.matchesLanguage(model.settings.preferredInterfaceLanguage) == true,
            let checked = try? cached.validated(observation: observation)
        {
            return checked
        }
        if requestIntent.playbackIntent == "play" || model.backgroundListening {
            return model.adaptive.readyMusicCard(observation)
        }
        return nil
    }
    func ownCurrentPage() {
        if let suggestedMusicSessionRole, model.activeRequest?.expectsPlayback == true,
            model.activeRequest?.musicSessionRole == nil {
            model.activeRequest?.musicSessionRole = suggestedMusicSessionRole
        }
        model.activeRequest?.browserResourceID = model.browser.id
        model.adoptRequestTask(.web(model.browser.id))
        activeTaskID = model.browser.id
        if requestIntent.playbackIntent == "play" || model.activeRequest?.expectsPlayback == true,
            let i = model.sideTasks.firstIndex(where: { $0.id == model.browser.id })
        {
            model.activeRequest?.expectsPlayback = true
            // Semantic user intent makes transport available before autoplay or UI preparation.
            model.sideTasks[i].listening = true
            model.sideTasks[i].prefersSource = false
        }
        if interfaceTicket?.taskID != model.browser.id {
            if let ticket = interfaceTicket { model.taskRevisions.finish(ticket) }
            interfaceTicket = model.beginTaskRevision(model.browser.id, .interface)
        }
    }
    @discardableResult
    func publishPendingSurface() async throws -> Bool {
        guard let plan = pendingSurface, let ticket = interfaceTicket, model.accepts(ticket) else { return false }
        let checked = try plan.validated(observation: try await model.observation())
        try Task.checkCancellation()
        guard model.accepts(ticket), model.browser.id == ticket.taskID else { return false }
        model.install(checked)
        model.upsertWebTask(checked)
        if !(checked.readings ?? []).isEmpty {
            try await model.browser.bindReadings(checked.readings ?? [])
            let observation = try await model.observation()
            model.updateLiveReadings(ticket.taskID, data: observation)
            let actual = observation["readings"] as? [String: String] ?? [:]
            if !model.externalBrowser, let requested = recovery.siteDestination, let profile = model.browser.siteMemoryProfile,
                (checked.readings ?? []).allSatisfy({ !(actual[$0.key] ?? "").isEmpty }) {
                model.siteMemory.observe(requested: requested, page: observation, profile: profile, taskID: ticket.taskID, verifiedReading: true)
            }
            guard model.accepts(ticket), model.browser.id == ticket.taskID else { throw CancellationError() }
        }
        model.hasCustomSurface = true
        model.surfaceOrigin = "Generated"
        model.saveSession(force: true)
        if !model.isLiveTest, let key = SurfaceCache.pageKey(model.webURL) {
            model.adaptive.cache.put(checked, key: key)
        }
        return true
    }
    func context(_ observation: [String: Any], detail: String? = nil, offset: Int = 0) -> [String: Any] {
        // The next tool schema and its validation must refer to the same page evidence.
        model.lastObservation = observation
        var result = observation
        if model.activeRequest?.expectsPlayback == true || requestIntent.playbackIntent == "play" {
            if let links = observation["elements"] as? [[String: Any]] {
                result["elements"] = links.filter { !model.playbackSources.avoidsLink($0["href"] as? String, on: observation["url"] as? String ?? "") }
            }
            if observation["playbackFailed"] as? Bool == true {
                model.playbackSources.recordPlayerFailure(observation)
                result["error"] = PlaybackSourceUnavailable().localizedDescription
            }
        }
        if nativeRequestActive, !(observation["url"] as? String ?? "").isEmpty { ownCurrentPage() }
        if !model.externalBrowser,
            let task = model.sideTasks.first(where: { $0.id == model.browser.id }), task.isMediaTask,
            let queue = task.musicQueue, MusicTrack.videoID(task.sourceURL ?? "") != nil,
            let data = try? JSONEncoder().encode(queue),
            let value = try? JSONSerialization.jsonObject(with: data)
        {
            result["music_queue"] = value
        }
        if let plan = reusablePlan(observation) {
            result["reusable_ui"] = ["available": true, "title": plan.title ?? "Saved controls"]
        }
        var packet = AgentContext.page(result, detail: detail ?? requestIntent.contextDetail, offset: offset)
        if !model.externalBrowser, let requested = recovery.siteDestination, let profile = model.browser.siteMemoryProfile {
            model.siteMemory.observe(requested: requested, page: observation, profile: profile, taskID: activeTaskID)
            if let access = model.siteMemory.hint(url: requested, profile: profile) {
                if observation["loginFormVisible"] as? Bool == true || observation["browserLoginRejected"] as? Bool == true,
                    let route = SiteMemory.Route(requested, client: profile.client), !route.login,
                    let path = URLComponents(string: requested)?.percentEncodedPath {
                    // Keep the return route in this browser only. Drop analytics, return URLs and credentials.
                    model.browser.pendingSignInEntry = access.origin + path
                    if model.browser.waitingForInterface { model.browser.releaseInterface() }
                    if let index = model.sideTasks.firstIndex(where: { $0.id == model.browser.id }) {
                        model.sideTasks[index].prefersSource = true
                    }
                }
                var history = ["origin": access.origin, "operation": access.operation, "observation": access.detail, "observed": access.date.ISO8601Format()]
                if ModelContextBudget.estimate(history) > 190 { history["observation"] = access.access.description }
                if ModelContextBudget.estimate(history) <= 190 { packet["previousAccess"] = history }
                if model.browser.pendingSignInEntry != nil, observation["loginFormVisible"] as? Bool == true {
                    packet["next"] = "The source is ready in the side screen. Ask the human to sign in there."
                }
            } else if let pending = model.browser.pendingSignInEntry,
                SiteMemory.Route(pending, client: profile.client)?.key == SiteMemory.Route(requested, client: profile.client)?.key {
                model.browser.pendingSignInEntry = nil
            }
        }
        return packet
    }

}
