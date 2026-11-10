#if DEBUG
    import AppKit

    @MainActor
    enum PreparationCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message("Check failed: " + label) }
                checks.append(label)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(250)) }
            for id in model.sideTasks.filter({ $0.kind == .web }).map(\.id) { model.closeTask(id) }
            model.sideTasks.removeAll()
            model.refreshTaskClock()
            _ = try model.startTimer(seconds: 600, title: "Tea")
            _ = try model.startTimer(seconds: 900, title: "Break")
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
            model.settings.autoAdapt = false
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
            defer { model.agent.interpretationOverride = nil }
            var round = 0
            var preparingLayout = false
            func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
                [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": UUID().uuidString, "type": "function",
                            "function": ["name": name, "arguments": JSONText.encode(arguments)],
                        ]
                    ],
                ]
            }
            model.agent.completionOverride = { _ in
                round += 1
                if round == 1 {
                    try await Task.sleep(for: .milliseconds(700))
                    return call("navigate", ["url": "http://127.0.0.1:19244/fixture?preparing"])
                }
                if round == 2 { return call("control_media", ["operation": "play"]) }
                preparingLayout = true
                model.activity = "Building controls…"
                try await Task.sleep(for: .seconds(20))
                return call("finish", ["outcome": "media_playing", "reply": "Playing"])
            }
            model.selectChat(true)
            model.command = "youtube lofi"
            model.sendCommand()
            let placeholder = model.requestCardID
            try check(
                placeholder != nil && model.ambientTasks.first?.id == placeholder && model.ambientTasks.count == 2
                    && !model.shellExpanded,
                "Submission immediately occupies an ambient slot even when two older tasks already exist")
            try await pause()
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-preparing.png")
            for _ in 0..<60 {
                if preparingLayout { break }
                try await pause()
            }
            let pageID = model.browser.id
            try check(
                preparingLayout && model.busy
                    && model.microMediaTasks.contains(where: { $0.id == pageID && $0.playing }),
                "Audible media exposes its native pause control while the model is still preparing the interface")
            try check(
                model.requestCardID == nil && !model.sideTasks.contains(where: { $0.id == placeholder })
                    && model.ambientTasks.first?.id == pageID && !model.shellExpanded,
                "The webpage replaces its preparing entry in place without a duplicate card or foreground expansion")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-playing-before-layout.png")
            model.controlMedia(pageID, operation: "toggle")
            for _ in 0..<20 {
                if !model.busy && model.sideTasks.first(where: { $0.id == pageID })?.playing == false { break }
                try await pause()
            }
            try await Task.sleep(for: .seconds(1))
            try check(
                !model.busy && model.sideTasks.first(where: { $0.id == pageID })?.playing == false,
                "Pausing during preparation stays paused and stops the agent from resuming playback")
            model.agent.completionOverride = { _ in
                try await Task.sleep(for: .seconds(20))
                return ["role": "assistant", "content": "Should be cancelled"]
            }
            model.command = "Prepare another task"
            model.sendCommand()
            let cancelledID = model.requestCardID!
            model.closeTask(cancelledID)
            for _ in 0..<20 {
                if !model.busy { break }
                try await pause()
            }
            try check(
                !model.busy && model.requestCardID == nil && !model.sideTasks.contains(where: { $0.id == cancelledID }),
                "Closing the preparing task cancels its request and removes its entry")
            model.agent.completionOverride = { _ in throw AppError.message("Fixture service unavailable") }
            model.command = "Prepare a failing task"
            model.sendCommand()
            let failedID = model.requestCardID!
            for _ in 0..<20 {
                if !model.busy { break }
                try await pause()
            }
            try check(
                model.sideTasks.first(where: { $0.id == failedID })?.status == "Task failed" && !model.shellExpanded,
                "A failed request replaces preparation with an inspectable error without reopening the window")
            model.closeTask(failedID)
            model.closeTask(pageID)
            model.agent.completionOverride = nil
            model.settings.main = Endpoint()
            return checks
        }
    }
#endif
