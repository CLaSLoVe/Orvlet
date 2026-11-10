#if DEBUG
    import AppKit

    @MainActor
    enum ScenarioCheck {
        static func run(_ model: AppModel, delegate: AppDelegate? = nil) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            Diagnostics.begin(
                CommandLine.arguments.contains("--wiki-only")
                    ? "/tmp/orvlet-wikipedia.jsonl"
                    : CommandLine.arguments.contains("--video-only")
                        ? "/tmp/orvlet-video-retry.jsonl" : "/tmp/orvlet-scenarios.jsonl")
            let scenarios =
                CommandLine.arguments.contains("--wiki-only")
                ? [
                    "Open https://en.wikipedia.org/wiki/Geometry and generate a compact HTML card for looking up related topics using only actual observed page controls. Use English UI labels. Do not log in."
                ]
                : CommandLine.arguments.contains("--video-only")
                    ? [
                        "Open https://www.w3schools.com/html/html5_video.asp and play the example video. I want to watch it. Use the observed page capabilities to compose useful compact controls."
                    ]
                    : [
                        "打开 https://news.ycombinator.com/ ，翻到下一页，然后根据实际网页能力生成一个方便继续浏览新闻的袖珍界面。不要登录。",
                        "打开 https://en.wikipedia.org/ ，查找 Geometry，然后根据实际网页能力生成一个方便继续查找百科词条的袖珍界面。不要登录。",
                    ]
            var failed = false
            for (index, prompt) in scenarios.enumerated() {
                model.pinned = false
                model.taskFailed = false
                model.endBackgroundListening()
                model.busy = true
                model.latestIntent = prompt
                model.messages = []
                model.messages.append(ChatMessage(text: prompt, isUser: true))
                Diagnostics.record("scenario_start", ["index": index])
                do {
                    let reply = try await model.agent.run(prompt)
                    model.messages.append(ChatMessage(text: reply, isUser: false))
                    let page = try await model.observation()
                    guard model.surface.markup != nil else {
                        throw AppError.message("Real provider did not produce HTML markup")
                    }
                    if let delegate {
                        model.busy = false
                        model.upsertWebTask(model.surface, activate: true)
                        model.selectTask(model.browser.id, expanded: true)
                        model.pinned = true
                        try await Task.sleep(for: .milliseconds(1000))
                        try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-scenario-\(index).png")
                    }
                    Diagnostics.record(
                        "scenario_complete",
                        [
                            "index": index, "url": model.webURL,
                            "components": model.surface.components.map { $0.kind.rawValue },
                            "viewport": page["viewport"] ?? [:],
                            "reply": reply,
                            "plan": try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.surface)),
                        ])
                } catch {
                    failed = true
                    model.taskFailed = true
                    model.messages.append(ChatMessage(text: error.localizedDescription, isUser: false))
                    Diagnostics.record("scenario_failed", ["index": index, "reason": error.localizedDescription])
                }
            }
            model.pinned = true
            model.busy = false
            model.activity = ""
            model.showPage()
            Diagnostics.record("scenarios_done", ["ok": !failed])
            if CommandLine.arguments.contains("--exit-after-check") { exit(failed ? 1 : 0) }
        }
    }
#endif
