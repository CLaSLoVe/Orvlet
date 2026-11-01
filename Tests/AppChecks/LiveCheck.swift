#if DEBUG
import AppKit
import WebKit

@MainActor
enum LiveCheck {
    static func layout(_ model: PetModel) async {
        model.persistHistory = false; model.isLiveTest = true
        model.settings.autoAdapt = false; model.busy = true
        model.settings.allowAgents = false
        Diagnostics.begin("/tmp/orvlet-layout.jsonl")
        let rememberedBefore = model.preferredWebSize
        do {
            model.surface = .webpage; model.selectChat(false)
            _ = try await model.browser.action(["action":"navigate", "url":"http://127.0.0.1:19244/fixture"])
            _ = try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').loop=true; document.querySelector('audio').volume=0.05")
            _ = try await model.browser.action(["action":"media", "operation":"play"])
            let plan = SurfacePlan(components: [SurfaceComponent(kind: .media), SurfaceComponent(kind: .transport, actions: [SurfaceAction(label: "Play / Pause", icon: "playpause.fill", binding: PageBinding(action: "media", operation: "toggle"))]), SurfaceComponent(kind: .slider, binding: PageBinding(action: "media", operation: "seek"), valueSource: "mediaTime")], width: 280, height: 150)
            model.install(plan)
            model.busy = false
            model.beginBackgroundListening()
            model.pointerChanged(true); model.reveal()
            try await Task.sleep(for: .milliseconds(400))
            _ = try await model.agent.execute("finish", ["outcome":"media_playing", "reply":"playing"])
            Diagnostics.record("clicked_webpage", ["verified":true,"width":model.windowSize.width,"height":model.windowSize.height])
            model.pointerChanged(false)
            try await Task.sleep(for: .milliseconds(900))
            _ = try await model.agent.execute("finish", ["outcome":"media_playing", "reply":"playing"])
            Diagnostics.record("collapsed", ["verified":true])
            model.selectChat(true)
            _ = try await model.agent.execute("finish", ["outcome":"media_playing", "reply":"playing"])
            Diagnostics.record("chat", ["verified":true])
            model.pointerChanged(true); model.reveal()
            model.selectChat(false)
            _ = try await model.browser.action(["action":"media", "operation":"pause"])
            model.pinned = true
            let viewport = try await model.observation()
            guard model.preferredWebSize == rememberedBefore else { throw AgentError.message("Animation overwrote the remembered webpage size") }
            Diagnostics.record("ready", ["width":model.windowSize.width,"height":model.windowSize.height,"viewport":viewport["viewport"] ?? [:], "savedSizePreserved":true])
            model.rememberWebSize(NSSize(width: 1, height: 1))
            model.onResize?(model.windowSize)
            try await Task.sleep(for: .milliseconds(350))
            guard let panel = NSApp.windows.first(where: { $0 is PetPanel }),
                  panel.frame.width >= PetModel.minimumWebSize.width, panel.frame.height >= PetModel.minimumWebSize.height,
                  panel.contentView?.layer?.masksToBounds == true else { throw AgentError.message("Minimum window or native clipping failed") }
            Diagnostics.record("minimum_window", ["width":panel.frame.width,"height":panel.frame.height,"cornerRadius":panel.contentView?.layer?.cornerRadius ?? 0, "clipped":true])
        } catch { Diagnostics.record("failed", ["reason":error.localizedDescription]) }
        model.busy = false
    }

    static func run(_ model: PetModel) async {
        model.persistHistory = false
        model.isLiveTest = true
        model.settings.autoAdapt = true
        model.busy = true
        Diagnostics.begin("/tmp/orvlet-live.jsonl")
        guard model.settings.main.isConfigured else { Diagnostics.record("failed", ["reason": "Missing model configuration"]); return }
        // Credentials are read inside the app and never logged or exported.
        let prompt = "Play some relaxed lofi music on YouTube. Pick one track and start listening without signing in."
        model.latestIntent = prompt
        model.messages = [ChatMessage(text: prompt, isUser: true)]
        model.selectChat(true)
        Diagnostics.record("start", ["model": model.settings.main.model])
        do {
            let reply = try await model.agent.run(prompt)
            model.messages.append(ChatMessage(text: reply, isUser: false))
            let initial = try await model.observation()
            try await Task.sleep(for: .seconds(3))
            let later = try await model.observation()
            guard later["audible"] as? Bool == true,
                  (later["currentTime"] as? Double ?? 0) > (initial["currentTime"] as? Double ?? 0) else {
                throw AgentError.message("Live playback did not advance audibly")
            }
            Diagnostics.record("complete", ["playing": later["playing"] as? Bool ?? false,
                "currentTime": later["currentTime"] as? Double ?? 0,
                "advanced": (later["currentTime"] as? Double ?? 0) > (initial["currentTime"] as? Double ?? 0),
                "path": URL(string: model.webURL)?.path ?? "", "components": model.surface.components.map { $0.kind.rawValue },
                "width": model.surface.width, "height": model.surface.height,
                "reply": String(reply.prefix(160))])
            _ = try await model.performBrowserAction(["action":"media", "operation":"pause"])
            let paused = try await model.observation()
            guard paused["playing"] as? Bool == false else { throw AgentError.message("Pause binding failed") }
            _ = try await model.performBrowserAction(["action":"media", "operation":"play"])
            model.collapse()
            let compactStart = try await model.observation()
            try await Task.sleep(for: .seconds(3))
            let compactEnd = try await model.observation()
            guard compactEnd["audible"] as? Bool == true,
                  (compactEnd["currentTime"] as? Double ?? 0) > (compactStart["currentTime"] as? Double ?? 0) else { throw AgentError.message("Collapsed playback did not continue") }
            Diagnostics.record("controls", ["pause":true, "resume":true, "collapsedPlayback":true])
            // A separate public webpage tests generic video discovery and composition.
            let videoPrompt = "Open https://www.w3schools.com/html/html5_video.asp and play the example video. I want to watch it in the webpage. Build only useful compact controls from the observed page."
            model.latestIntent = videoPrompt; model.agent.conversation = []
            model.endBackgroundListening(); model.showPage()
            let videoReply = try await model.agent.run(videoPrompt)
            let videoBefore = try await model.observation()
            try await Task.sleep(for: .seconds(2))
            let videoAfter = try await model.observation()
            guard videoAfter["playing"] as? Bool == true,
                  (videoAfter["currentTime"] as? Double ?? 0) > (videoBefore["currentTime"] as? Double ?? 0),
                  model.surface.needsVisual else { throw AgentError.message("Video scenario did not retain an advancing video webpage") }
            Diagnostics.record("video_complete", ["url":model.webURL, "reply":videoReply,
                "components":model.surface.components.map { $0.kind.rawValue },
                "actions":model.compactActions.map { ["label":$0.label,"binding":$0.binding.dictionary] },
                "viewport":videoAfter["viewport"] ?? [:], "advancing":true])
            _ = try await model.performBrowserAction(["action":"media", "operation":"pause"])
            if model.settings.useFast {
                do {
                    let fastKey = try await SecretStore.load("fast")
                    let started = Date()
                    let answers = try await JevClient.judge(endpoint:model.settings.fast, key:fastKey, state:["intent":prompt,"playing":true], questions:["audio":"Does the user want background music?"])
                    Diagnostics.record("jev", ["seconds":Date().timeIntervalSince(started), "valid":answers["audio"] != nil])
                } catch { Diagnostics.record("jev_failed", ["reason":error.localizedDescription]) }
            }
            _ = try await model.performBrowserAction(["action":"media", "operation":"pause"])
            model.selectChat(false); model.pinned = true
        } catch {
            model.taskFailed = true
            model.messages.append(ChatMessage(text: error.localizedDescription, isUser: false))
            Diagnostics.record("failed", ["reason": error.localizedDescription])
        }
        model.settings.autoAdapt = false
        model.busy = false; model.activity = ""
        if CommandLine.arguments.contains("--exit-after-check") { NSApp.terminate(nil) }
    }
}
#endif
