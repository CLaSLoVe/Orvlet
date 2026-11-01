#if DEBUG
import AppKit

@MainActor
enum ConversationCheck {
    static func run(_ model: PetModel) async {
        model.isLiveTest = true; model.persistHistory = false
        model.settings.autoAdapt = false; model.settings.allowAgents = false
        Diagnostics.begin("/tmp/orvlet-conversation-live.jsonl")
        model.selectChat(true)
        model.command = "Open https://www.w3schools.com/html/html5_video.asp and play the example video. Build useful compact controls."
        model.sendCommand()
        let deadline = Date().addingTimeInterval(120)
        while model.busy && !model.agent.waitingForDecision && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.agent.waitingForDecision else { Diagnostics.record("failed", ["reason":"No model request started"]); return }
        try? await Task.sleep(for: .milliseconds(300))
        let changed = Date()
        model.command = "Change of plan: open https://example.com instead. Do not play any media. Keep the interface minimal."
        model.sendCommand()
        Diagnostics.record("message_sent_during_request", ["accepted":model.command.isEmpty, "busy":model.busy])
        while model.busy && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard !model.busy, URL(string:model.webURL)?.host == "example.com", !model.isPlaying, !model.taskFailed else {
            Diagnostics.record("failed", ["reason":"Updated request was not completed", "url":model.webURL]); model.cancel(); return
        }
        Diagnostics.record("updated_request_complete", ["seconds":Date().timeIntervalSince(changed), "url":model.webURL])
        let warm = Date()
        model.command = "Stay on this page and keep its existing controls. Tell me only its title."
        model.sendCommand()
        while model.busy && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard !model.busy, !model.taskFailed else { Diagnostics.record("failed", ["reason":"Warm follow-up failed"]); model.cancel(); return }
        Diagnostics.record("warm_followup_complete", ["seconds":Date().timeIntervalSince(warm), "reply":model.messages.last?.text ?? ""])
        model.pinned = true; model.showPage()
    }
}
#endif
