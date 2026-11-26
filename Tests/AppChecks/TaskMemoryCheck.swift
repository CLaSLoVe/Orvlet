#if DEBUG
    import Foundation

    @MainActor
    enum TaskMemoryCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func require(_ success: Bool, _ name: String) throws {
                guard success else { throw AppError.message(name) }
                checks.append(name)
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-task-memory-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let name = "orvlet.task-memory." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let db = root.appendingPathComponent("memory.sqlite3")
            let model = AppModel(defaults: defaults, memoryURL: db)
            guard model.memoryDB.isAvailable else { throw AppError.message("Could not open the temporary task memory SQLite database") }
            let owner = UUID(), other = UUID()
            let history = (0..<40).map { index -> ChatMessage in
                let text: String = switch index {
                case 0: "只看港股，金额用港币。"
                case 6: "密码 ORVLET_FAKE_CREDENTIAL"
                case 17: "金额改用美元。"
                default: "普通进度 \(index)"
                }
                return ChatMessage(taskID: owner, text: text, isUser: index.isMultiple(of: 2) || index == 17)
            }
            model.messages = Array(history.prefix(18))
            var endpoint = Endpoint(baseURL: "http://127.0.0.1:19244/api-wire/task-memory/v1", model: "fixture")
            endpoint.options.authentication = .none
            let connection = ModelConnection(endpoint: endpoint, keyAccount: "unused")
            var requests = 0
            var fixtureError: Error?
            model.taskMemoryCompressor = { messages, existing in
                requests += 1
                do {
                    let changes = try await TaskMemory.summarize(messages, previous: existing, connection: connection)
                    var candidate = TaskMemoryLedger()
                    candidate.facts = existing
                    try TaskMemory.apply(changes, batch: messages, to: &candidate)
                    return changes
                }
                catch { fixtureError = error; throw error }
            }
            model.openTaskConversation(owner)
            await model.taskMemoryJobs[owner]?.job.value
            if let fixtureError { throw fixtureError }
            try require(model.taskMemoryLedger(owner).facts.contains { $0.quote == "金额用港币" },
                        "Initial background compaction preserves the original currency")
            model.messages += Array(history.dropFirst(18)) + [ChatMessage(taskID: other, text: "Weather only", isUser: true)]
            model.openTaskConversation(owner)
            await model.taskMemoryJobs[owner]?.job.value
            if let fixtureError { throw fixtureError }
            let ledger = model.taskMemoryLedger(owner)
            guard requests == 2 && ledger.processed.count == 28 && ledger.facts.count == 2 else {
                throw AppError.message("Task memory fixture made \(requests) requests, recorded \(ledger.processed.count) messages and \(ledger.facts.count) facts")
            }
            try require(model.taskMemoryJobs[owner] == nil,
                        "Opening an old task compacts the first 28 messages through the background model in two bounded batches")
            try require(ledger.facts.contains { $0.quote == "只看港股" } && ledger.facts.contains {
                $0.quote == "金额改用美元" && $0.sources == [history[0].id, history[17].id]
            }, "Currency correction preserves source order and the unrelated market constraint")
            let drained = try await model.compactTaskMemory(owner)
            try require(!drained && requests == 2, "A retry at the committed boundary makes no additional summary request")
            let reopened = AppModel(defaults: defaults, memoryURL: db)
            reopened.settings.main = endpoint
            reopened.settings.useFast = false
            reopened.sideTasks = [SideTask(id: owner, kind: .result, title: "持仓")]
            let reply = try await reopened.agent.run("导出时用什么币种？只回复币种。", taskID: owner)
            try require(reply == "美元", "Reopened executor sends corrected currency and original market on the wire and delivers the USD answer")
            try require(!JSONText.encode(reopened.taskConversation(other)).contains("只看港股"),
                        "Unrelated task cannot recall the market constraint")
            let original = JSONText.encode(reopened.recalledTaskConversation(owner, query: "最早要求用什么币种？", excluding: nil))
            try require(original.contains("金额用港币"), "An explicit historical question can retrieve the original wording")
            reopened.selectChat(true, conversation: owner)
            reopened.command = "忘掉币种"
            reopened.sendCommand()
            let forgotten = JSONText.encode(reopened.recalledTaskConversation(owner, query: "最早要求用什么币种？", excluding: nil))
            try require(!forgotten.contains("港币") && !forgotten.contains("金额改用美元") && forgotten.contains("只看港股"),
                        "Chat forgetting suppresses relevant old originals and preserves the separate market fact")
            _ = reopened.appendMessage("金额重新用港币。", isUser: true, taskID: owner)
            try require(JSONText.encode(reopened.taskConversation(owner)).contains("金额重新用港币"),
                        "An explicit new instruction can establish the forgotten preference again")
            let many = AppModel(defaults: UserDefaults(suiteName: "orvlet.large-memory." + UUID().uuidString)!)
            many.persistHistory = false
            for count in [40, 400] {
                many.messages = (0..<count).map { ChatMessage(taskID: owner, text: "普通进度 \($0)", isUser: true) }
                let output = many.recalledTaskConversation(owner, query: "", excluding: nil)
                let recent = output.filter { $0[ModelWire.contextPriorityKey] as? Int == 2 }
                let old = output.filter { $0[ModelWire.contextPriorityKey] as? Int != 2 }
                let tokens = old.reduce(0) { $0 + ModelContextBudget.tokens($1["content"] as? String ?? "") + 8 }
                try require(recent.count == 12 && tokens <= 800, "\(count)-message history keeps twelve recent turns and at most 800 estimated old-memory tokens")
            }
            let unsafe = [TaskMemoryChange(operation: "set", kind: .constraint, topic: "币种", source: UUID(), quote: "美元")]
            var invalid = TaskMemoryLedger()
            do {
                try TaskMemory.apply(unsafe, batch: history, to: &invalid)
                throw AppError.message("Unsupported memory evidence accepted")
            } catch is PipelineFailure {
                checks.append("A fabricated source is rejected")
            }
            many.taskMemoryCompressor = { _, _ in throw URLError(.notConnectedToInternet) }
            do {
                _ = try await many.compactTaskMemory(owner)
                throw AppError.message("Offline compaction advanced")
            } catch is URLError {
                try require(many.taskMemoryLedger(owner).processed.isEmpty && !many.taskConversation(owner).isEmpty,
                            "Offline compression preserves the cursor and the next request retains bounded fallback context")
            }
            many.taskMemoryCompressor = { _, _ in
                _ = many.forgetTaskMemory(owner)
                many.messages.removeAll { $0.taskID == owner }
                return []
            }
            let stale = try await many.compactTaskMemory(owner)
            try require(!stale && many.taskMemoryLedger(owner).processed.isEmpty,
                        "An in-flight compression cannot recreate a cleared conversation")
            let promoted = UUID()
            _ = reopened.restoreHistoryTask(owner, showCard: false)
            reopened.beginAmbientRequest("Promote to a card", taskID: owner)
            reopened.adoptRequestTask(.workspace(promoted))
            try require(reopened.taskMemoryLedger(owner).facts.isEmpty && reopened.taskMemoryLedger(promoted).facts.contains {
                $0.quote == "只看港股" && $0.sources.contains(history[0].id)
            } && !reopened.recallableMessages(promoted).contains { $0.id == history[17].id },
                        "Promoting a conversation transfers its facts, source evidence and forgotten-message markers")
            try require(reopened.eraseConversationData(promoted) && reopened.taskMemoryLedger(promoted).facts.isEmpty,
                        "Deleting a promoted task removes its transferred memory")
            return checks
        }
    }
#endif
