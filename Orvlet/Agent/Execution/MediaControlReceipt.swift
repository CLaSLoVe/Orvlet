import Foundation

@MainActor
extension AgentController {
    /// Transport proof belongs to the player, independent of page composition.
    func verifiedPlayback(requireAudible: Bool) async throws -> [String: Any] {
        let initial = try await model.observation()
        try await Task.sleep(for: .milliseconds(1100))
        let later = try await model.observation()
        let advanced = (later["currentTime"] as? Double ?? 0) > (initial["currentTime"] as? Double ?? 0) + 0.2
        guard later["playing"] as? Bool == true, later["adPlaying"] as? Bool != true, advanced,
            !requireAudible || later["audible"] as? Bool == true
        else {
            throw AppError.message(
                "Playback is not yet verified. Check the player, mute, ads, sign-in or loading state and continue.")
        }
        return later
    }

    /// A capability verifies its real effect. Routing (Jev or main model) does not change execution.
    func executeMediaControl(_ input: [String: Any]) async throws -> [String: Any] {
        guard let operation = input["operation"] as? String, PageBinding.mediaOperations.contains(operation) else {
            throw AppError.message("Choose a supported playback control.")
        }
        let revision = steeringRevision
        if let owner = model.requestPageID { try await model.prepareTaskSource(owner) }
        let before = try await model.observation()
        let queue = model.sideTasks.first { $0.id == model.browser.id }?.musicQueue
        var action = input
        action["action"] = "media"
        _ = try await dispatch("act", action)
        try Task.checkCancellation()
        var after = try await model.observation()
        let op = operation == "toggle" ? (before["playing"] as? Bool == true ? "pause" : "play") : operation
        if ["play", "next", "previous"].contains(op) {
            after = try await verifiedPlayback(
                requireAudible:
                    before["muted"] as? Bool != true && (before["volume"] as? Double ?? 1) > 0)
        }
        let sameSource = before["url"] as? String == after["url"] as? String
        let value = (input["value"] as? NSNumber)?.doubleValue
        let confirmed: Bool
        switch op {
        case "play": confirmed = sameSource && after["playing"] as? Bool == true
        case "pause": confirmed = sameSource && after["hasMedia"] as? Bool == true && after["playing"] as? Bool == false
        case "next", "previous":
            let expected = op == "next" ? queue?.upcoming.first?.id : queue?.previous.last?.id
            confirmed =
                expected.map { MusicTrack.videoID(after["url"] as? String ?? "") == $0 }
                ?? (!sameSource && after["playing"] as? Bool == true)
        case "volume":
            confirmed = sameSource && value.map { abs((after["volume"] as? Double ?? -1) - $0) < 0.02 } == true
        case "seek":
            confirmed = sameSource && value.map { abs((after["currentTime"] as? Double ?? -10) - $0) < 3 } == true
        case "mute", "unmute": confirmed = sameSource && after["muted"] as? Bool == (op == "mute")
        case "toggleMute": confirmed = sameSource && (before["muted"] as? Bool) != (after["muted"] as? Bool)
        case "loop", "unloop": confirmed = sameSource && after["looping"] as? Bool == (op == "loop")
        default: confirmed = false
        }
        guard revision == steeringRevision else { throw CancellationError() }
        guard confirmed else {
            clearEffectVerification()
            throw AppError.message("The player did not confirm the requested change.")
        }
        if ["play", "next", "previous"].contains(op), after["audible"] as? Bool == true {
            model.beginBackgroundListening()
        }
        if effectReply.isEmpty { verifyEffect(model.userText("已更新。", "Updated.")) }
        return ["verified": true, "operation": op, "state": AgentContext.page(after, detail: "state")]
    }
}
