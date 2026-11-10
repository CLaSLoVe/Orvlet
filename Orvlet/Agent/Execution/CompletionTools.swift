import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeCompletionTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "finish":
            if requestIntent.isNative {
                throw AppError.message(
                    "Local requests finish only through their native action or calendar_clarify, never through finish.")
            }
            let outcome = input["outcome"] as? String ?? ""
            if outcome == "blocked" {
                failureReason = input["reply"] as? String ?? "Unable to complete this page action."
                return ["blocked": true]
            }
            if requestIntent.requiresFreshData && !freshSourceLoaded {
                throw AppError.message(
                    "Refresh the source before reporting current external facts. A saved view or old observation is not fresh data."
                )
            }
            if unresolvedCalendar {
                throw AppError.message("The calendar action is not verified. Do not claim it succeeded.")
            }
            if outcome == "answer", requestIntent.kind == .general {
                throw AppError.message("A task request needs an executed and verified result, not finish(answer).")
            }
            if outcome == "task_ready" {
                if let receipt = taskControlReceipt, receipt.taskID == activeTaskID,
                    model.sideTasks.contains(where: { $0.id == receipt.taskID })
                {
                    guard revision == steeringRevision else { throw CancellationError() }
                    verifyEffect(receipt.reply)
                    return ["verified": true, "task_id": receipt.taskID.uuidString]
                }
                guard taskSurfaceReady,
                    model.sideTasks.contains(where: { $0.id == activeTaskID && $0.taskSurface != nil }),
                    !attemptedCode || codeReceipt != nil
                else {
                    throw AppError.message("The task interface and calculation are not verified yet.")
                }
                try await TaskVerification.verify(activeTaskID, intent: requestIntent, model: model)
                guard revision == steeringRevision else { return ["superseded": true] }
                verifyEffect(input["reply"] as? String ?? "Your task is ready.")
                return ["verified": true, "task_id": activeTaskID.uuidString]
            }
            if input["source_only"] as? Bool == true {
                guard outcome == "page_ready", ![.live, .advancing, .interactive].contains(requestIntent.behavior),
                    let raw = input["readings"] as? [[String: Any]], !raw.isEmpty
                else {
                    throw AppError.message("A source-only snapshot needs exact observed readings and page_ready.")
                }
                let readings = try JSONDecoder().decode(
                    [CardReading].self, from: JSONSerialization.data(withJSONObject: raw))
                let proof = input["outcomeEvidence"] as? [[String: Any]] ?? []
                let primary = proof.first?["valueKey"] as? String ?? readings.last!.key
                let observation = try await model.observation()
                pendingSurface = try SurfacePlan.sourceFallback(
                    readings: readings, primary: primary, observation: observation)
            }
            if interfaceAttempted && pendingSurface == nil {
                throw AppError.message(
                    "The requested interface has not passed validation. Repair the last compose_ui or reuse_saved_ui bindings before claiming completion, or finish(blocked) with the actual reason."
                )
            }
            if attemptedTaskWork {
                throw AppError.message(
                    "Verify the generated task with finish(task_ready), not a webpage or answer outcome.")
            }

            if requestIntent.playbackIntent == "play", !["media_playing", "video_playing"].contains(outcome) {
                throw AppError.message(
                    "The human requested playback. Verify media_playing or video_playing; opening a page is not playback."
                )
            }
            if requestIntent.playbackIntent == "pause", outcome != "media_paused" {
                throw AppError.message("Verify media_paused before completing a pause request.")
            }
            if pendingSurface == nil, !interfaceAttempted,
                ["media_playing", "video_playing", "media_paused"].contains(outcome)
            {
                pendingSurface = reusablePlan(try await model.observation())
            }
            var installedInterface = false
            if model.browser.waitingForInterface, outcome == "media_playing" || outcome == "video_playing" {
                installedInterface = try await publishPendingSurface()
                guard installedInterface || (model.hasCustomSurface && model.interfaceJobs[model.browser.id] == nil)
                else {
                    throw AppError.message(
                        "Wait for the current interface revision before starting playback in interface-first mode.")
                }
                guard revision == steeringRevision else { return ["superseded": true] }
                model.browser.releaseInterface()
                await model.browser.applyPlaybackPolicy()
                _ = try await model.performBrowserAction(["action": "media", "operation": "play"])
            }
            if outcome == "media_playing" || outcome == "video_playing" {
                _ = try await verifiedPlayback(requireAudible: outcome == "media_playing")
            } else if outcome == "media_paused" {
                let state = try await model.observation()
                guard state["hasMedia"] as? Bool == true, state["playing"] as? Bool == false else {
                    throw AppError.message("Media is not paused yet.")
                }
            } else if outcome == "page_ready" {
                let state = try await model.observation()
                guard !(state["url"] as? String ?? "").isEmpty,
                    !model.webLoading || BrowserController.contentReady(state), model.webError == nil
                else { throw AppError.message("The page is still loading.") }
                if [.live, .advancing].contains(requestIntent.behavior) {
                    let plan = pendingSurface ?? model.surface
                    let keys = Set((plan.readings ?? []).map(\.selector))
                    guard !keys.isEmpty else {
                        throw AppError.message("A live page task needs actual bound readings.")
                    }
                    func values(_ page: [String: Any]) -> [String: String] {
                        Dictionary(
                            uniqueKeysWithValues: (page["readables"] as? [[String: Any]] ?? []).filter {
                                keys.contains($0["selector"] as? String ?? "")
                            }.compactMap { item in
                                guard let selector = item["selector"] as? String, let value = item["text"] as? String,
                                    !value.isEmpty
                                else { return nil }
                                return (selector, value)
                            })
                    }
                    let first = values(state)
                    guard first.count == keys.count else {
                        throw AppError.message("The live source has missing readings.")
                    }
                    if requestIntent.behavior == .advancing {
                        try await Task.sleep(for: .milliseconds(2100))
                        let later = try await model.observation()
                        guard later["url"] as? String == state["url"] as? String, values(later) != first else {
                            throw AppError.message(
                                "The bound source values did not advance. Verify the actual running source, not static page text."
                            )
                        }
                    }
                }
            } else if outcome != "answer" || operatedPage || !requestIntent.requirements.isEmpty {
                throw AppError.message("Verify the page outcome before finishing.")
            }
            if !requestIntent.requirements.isEmpty {
                try OutcomeEvidence.verify(
                    requestIntent.requirements, evidence: input["outcomeEvidence"] as? [[String: Any]] ?? [],
                    observation: try await model.observation(), plan: pendingSurface ?? model.surface)
            }
            guard revision == steeringRevision else { return ["superseded": true] }
            try Task.checkCancellation()
            if !installedInterface { _ = try await publishPendingSurface() }
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            if let ticket = interfaceTicket { model.taskRevisions.finish(ticket) }
            if outcome == "page_ready", model.browser.waitingForInterface {
                await model.browser.webView.pauseAllMediaPlayback()
                model.browser.releaseInterface()
                await model.browser.applyPlaybackPolicy()
            }
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            if outcome == "media_playing" {
                model.beginBackgroundListening()
            } else if outcome == "video_playing" || outcome == "page_ready" {
                model.endBackgroundListening(clearTaskIntent: true)
                if let i = model.sideTasks.firstIndex(where: { $0.id == model.browser.id }) {
                    model.sideTasks[i].prefersSource = outcome == "video_playing" || model.surface.markup == nil
                }
            }
            if outcome != "answer" { model.upsertWebTask(model.surface, activate: true) }
            verifyEffect(input["reply"] as? String ?? "Done.")
            return ["verified": true]
        default: throw AppError.message("Unsupported completion tool.")
        }
    }

}
