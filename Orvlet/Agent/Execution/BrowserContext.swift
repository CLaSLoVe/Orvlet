import Foundation

@MainActor
extension AgentController {
    func reusablePlan(_ observation: [String: Any]) -> SurfacePlan? {
        if model.hasCustomSurface, model.surface.markup != nil,
            let plan = try? model.surface.validated(observation: observation)
        {
            return plan
        }
        if let retained = model.browser.reusableMediaSurface(observation) { return retained }
        if let key = SurfaceCache.pageKey(observation["url"] as? String ?? ""),
            let cached = model.adaptive.cache.get(key), cached.markup != nil,
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
        model.adoptRequestTask(.web(model.browser.id))
        activeTaskID = model.browser.id
        if requestIntent.playbackIntent == "play",
            let i = model.sideTasks.firstIndex(where: { $0.id == model.browser.id })
        {
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
        return AgentContext.page(result, detail: detail ?? requestIntent.contextDetail, offset: offset)
    }

}
