import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeBrowserTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "find_music":
            let music = try JSONDecoder().decode(MusicRequest.self, from: JSONSerialization.data(withJSONObject: input))
            do {
                let reply = try await executeMusicRequest(
                    music, key: try await model.loadModelKey(for: requestConnection), revision: revision)
                return ["verified": true, "reply": reply]
            } catch is MusicDiscoveryUnavailable {
                return try await recoverMusicSearch(music)
            } catch is MusicSelectionUnavailable {
                return try await recoverMusicSearch(music)
            }
        case "observe":
            if model.requestPageID == nil {
                guard let id = model.activeRequest?.sourceCandidateID else { throw PipelineFailure.targetUnavailable }
                try await model.prepareTaskSource(id)
                ownCurrentPage()
            }
            return context(
                try await model.observation(), detail: input["detail"] as? String ?? "page",
                offset: input["offset"] as? Int ?? 0)
        case "reuse_ui":
            interfaceAttempted = true
            pendingSurface = nil
            let page = try await model.observation()
            guard revision == steeringRevision else { return ["superseded": true] }
            guard let plan = reusablePlan(page) else {
                throw AppError.message(
                    "Saved controls no longer match. Compose new controls from the current observation.")
            }
            pendingSurface = plan
            return ["ok": true, "reused": true]
        case "navigate":
            let destination = input["url"] as? String
            if !preparedBrowser {
                try model.prepareBrowserForNewTask(destination: destination)
                preparedBrowser = true
            }
            if let destination, let key = SurfaceCache.pageKey(destination), key == SurfaceCache.pageKey(model.webURL),
                URL(string: destination)?.fragment == URL(string: model.webURL)?.fragment,
                model.browser.webView.url != nil, !model.webLoading, model.webError == nil
            {
                operatedPage = true
                ownCurrentPage()
                if requestIntent.requiresFreshData && !freshSourceLoaded {
                    let page = try await model.performBrowserAction(["action": "reload", "fresh": true])
                    freshSourceLoaded = true
                    return context(page)
                }
                return context(try await model.observation())
            }
            if (model.activeRequest?.startPolicy ?? model.settings.taskStartPolicy) == .interfaceFirst,
                model.webURL.isEmpty, !model.externalBrowser
            {
                model.browser.waitForInterface()
                await model.browser.applyPlaybackPolicy()
            }
            model.browser.rememberMediaSurface(model.surface, url: model.webURL)
            var a = input
            a["action"] = "navigate"
            operatedPage = true
            ownCurrentPage()
            model.endBackgroundListening()
            model.hasCustomSurface = false
            if !model.pinned {
                model.install(.webpage)
                if !model.collapsed && !model.chatVisible { model.selectChat(false) }
            }
            let page = try await model.performBrowserAction(a)
            freshSourceLoaded = true
            return context(page, detail: "page")
        case "act":
            var input = input
            // Resolve an exact, unique accessible name when a provider omits role.
            // Never interpret arbitrary CSS, aliases or ambiguous matches as a target.
            if ["click", "type", "select", "submit"].contains(input["action"] as? String ?? ""), input["id"] == nil,
                input["role"] == nil,
                let name = input["name"] as? String
            {
                let observed = try await model.observation()
                let matches = (observed["elements"] as? [[String: Any]] ?? []).filter { $0["label"] as? String == name }
                if matches.count == 1, let id = matches.first?["id"] as? String { input["id"] = id }
            }
            operatedPage = true
            ownCurrentPage()
            if ["click", "type", "select", "submit"].contains(input["action"] as? String ?? "") {
                let hasID = !(input["id"] as? String ?? "").isEmpty
                let hasLocator = input["name"] is String && input["role"] is String
                let hasPoint = input["x"] is NSNumber && input["y"] is NSNumber && input["action"] as? String == "click"
                guard hasID || hasLocator || hasPoint else {
                    throw AppError.message(
                        "Missing target. Use id from observation.elements, or exact name AND role. Do not send CSS selectors. To play detected media, use action: media, operation: play."
                    )
                }
            }
            if input["action"] as? String == "media",
                input["operation"] as? String == "pause"
                    || (input["operation"] as? String == "toggle" && model.isPlaying),
                requestIntent.playbackIntent != "pause"
            {
                throw AppError.message(
                    "The user did not ask to pause. Keep the task running while preparing its interface.")
            }
            // Agent page clicks must not toggle an already playing player. Direct
            // human page interaction and native pause controls remain unrestricted.
            input["preservePlayback"] = requestIntent.playbackIntent != "pause"
            let actionResult = try await model.performBrowserAction(input)
            if actionResult["playbackDeferred"] as? Bool == true { return context(actionResult) }
            let page = try await (model.externalBrowser ? model.observation() : model.browser.settledObservation())
            if requestIntent.playbackIntent == "play"
                || (input["action"] as? String == "media"
                    && ["play", "toggle"].contains(input["operation"] as? String ?? "")),
                page["playing"] as? Bool == true, page["adPlaying"] as? Bool != true,
                let i = model.sideTasks.firstIndex(where: { $0.id == model.browser.id })
            {
                // Explicit agent playback intent, not incidental media on an information page.
                model.sideTasks[i].listening = true
                model.sideTasks[i].prefersSource = false
            }
            return context(page)
        case "compose_ui":
            interfaceAttempted = true
            pendingSurface = nil
            if model.requestCardID != nil { ownCurrentPage() }
            let plan = try InterfaceComposer.decodePlan(JSONText.encode(input))
            let mapped = try plan.validated(observation: model.lastObservation)
            let observation = try await model.observation()
            let checked = try mapped.validated(observation: observation)
            guard revision == steeringRevision else { return ["superseded": true] }
            pendingSurface = checked
            return [
                "ok": true, "components": checked.components.map { $0.kind.rawValue },
                "pending": "UI will appear after finish verifies the requested outcome",
            ]
        case "visibility":
            if model.pinned { return ["changed": false, "reason": "The user pinned this layout."] }
            switch input["state"] as? String {
            case "collapsed": model.collapse()
            case "expanded":
                guard !model.backgroundRequest else {
                    return [
                        "changed": false, "reason": "Work stays in the background; only the human opens the interface.",
                    ]
                }
                model.reveal()
            case "hidden": model.hide()
            default: throw AppError.message("Unknown display state.")
            }
            return ["ok": true]
        case "history":
            let query = (input["query"] as? String ?? "").lowercased()
            let day = input["day"] as? String ?? ""
            let date = DateFormatter()
            date.dateFormat = "yyyy-MM-dd"
            let entries = model.history.filter {
                (query.isEmpty || $0.title.lowercased().contains(query))
                    && (day.isEmpty || date.string(from: $0.date) == day)
            }
            return [
                "entries": entries.prefix(35).map {
                    [
                        "id": $0.id.uuidString, "title": $0.title, "url": $0.url, "kind": $0.kind,
                        "date": ISO8601DateFormatter().string(from: $0.date),
                    ]
                }
            ]
        case "restore":
            guard let id = input["id"] as? String, let entry = model.history.first(where: { $0.id.uuidString == id })
            else { throw AppError.message("History entry not found.") }
            model.restore(entry)
            return ["ok": true, "title": entry.title]
        default: throw AppError.message("Unsupported browser tool.")
        }
    }

    private func recoverMusicSearch(_ request: MusicRequest) async throws -> [String: Any] {
        guard request.placement == .replace else { throw MusicSelectionUnavailable() }
        var search = URLComponents(string: "https://www.youtube.com/results")!
        search.queryItems = [URLQueryItem(name: "search_query", value: request.query)]
        Diagnostics.record("music_search_fallback")
        var result = try await executeBrowserTool(
            "navigate", ["url": search.url!.absoluteString], revision: steeringRevision)
        result["next_step"] =
            "The initial music selection was inconclusive. Inspect real search results, refine if needed, and verify playback. Matching music radio is valid for a general style. Preserve the artist/title/version constraints."
        return result
    }

}
