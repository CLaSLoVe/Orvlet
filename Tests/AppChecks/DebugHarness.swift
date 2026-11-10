#if DEBUG
    import AppKit
    import SwiftUI

    /// The only owner of Debug launch modes. Production startup knows no test names.
    @MainActor
    enum DebugHarness {
        enum Mode: String, CaseIterable {
            case taskContinuityCheck = "--task-continuity-check"
            case requestPipelineLive = "--request-pipeline-live"
            case supportDiagnostics = "--support-diagnostics"
            case calendarCheck = "--calendar-check"
            case setupProbe = "--setup-probe"
            case triageLiveCheck = "--triage-live-check"
            case fastReuseLiveCheck = "--fast-reuse-live-check"
            case intentCheck = "--intent-check"
            case modelsPreview = "--models-preview"
            case modelAPICheck = "--model-api-check"
            case modelPolicyProbe = "--model-policy-probe"
            case selfCheck = "--self-check"
            case builtinCardsCheck = "--builtin-cards-check"
            case localDataCheck = "--local-data-check"
            case cacheSizeCheck = "--cache-size-check"
            case demoRecording = "--demo-recording"
            case deliveryCheck = "--delivery-check"
            case deliveryRestore = "--delivery-restore"
            case deliveryMedia = "--delivery-media"
            case deliveryHistory = "--delivery-history"
            case setupCheck = "--setup-check"
            case consistencyCheck = "--consistency-check"
            case taskHistoryCheck = "--task-history-check"
            case interfaceCheck = "--interface-check"
            case rankingLiveCheck = "--ranking-live-check"
            case taskAgentCheck = "--task-agent-check"
            case motionCheck = "--motion-check"
            case listeningCheck = "--listening-check"
            case musicCheck = "--music-check"
            case musicLiveCheck = "--music-live-check"
            case musicSourceCheck = "--music-source-check"
            case musicRequestCheck = "--music-request-check"
            case musicWorkflowCheck = "--music-workflow-check"
            case unifiedRequestLiveCheck = "--unified-request-live-check"
            case protectionCheck = "--protection-check"
            case commandWindowCheck = "--command-window-check"
            case workflowBenchmark = "--workflow-benchmark"
            case apiDataCheck = "--api-data-check"
            case clockCheck = "--clock-check"
            case preparationCheck = "--preparation-check"
            case sideScreenCheck = "--side-screen-check"
            case conversationCheck = "--conversation-check"
            case scenarioCheck = "--scenario-check"
            case layoutCheck = "--layout-check"
            case liveCheck = "--live-check"
            var requiresLiveServices: Bool {
                switch self {
                case .modelPolicyProbe, .requestPipelineLive, .calendarCheck, .triageLiveCheck, .fastReuseLiveCheck,
                    .intentCheck,
                    .demoRecording,
                    .deliveryCheck, .deliveryRestore,
                    .deliveryMedia, .deliveryHistory, .rankingLiveCheck, .taskAgentCheck, .workflowBenchmark,
                    .apiDataCheck, .clockCheck, .conversationCheck, .scenarioCheck, .liveCheck, .musicLiveCheck,
                    .musicSourceCheck, .musicRequestCheck, .musicWorkflowCheck, .unifiedRequestLiveCheck:
                    return true
                default: return false
                }
            }
        }
        static var pipelineSuite: String?
        static func pipelineModel() -> AppModel? {
            guard CommandLine.arguments.contains("--request-pipeline-live") else { return nil }
            let name = "orvlet.pipeline.live." + UUID().uuidString
            pipelineSuite = name
            let store = UserDefaults(suiteName: name)!
            if !CommandLine.arguments.contains("--empty-catalogue"),
                let recipes = UserDefaults.standard.data(forKey: "interfaceRecipes.v1")
            {
                store.set(recipes, forKey: "interfaceRecipes.v1")
            }
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            return model
        }
        static func selected(arguments: [String] = CommandLine.arguments) -> Mode? {
            let modes = Mode.allCases.filter { arguments.contains($0.rawValue) }
            guard modes.count <= 1 else {
                fputs("Choose one Debug check mode per launch.\n", stderr)
                exit(2)
            }
            return modes.first
        }
        static func beforeWindows(_ delegate: AppDelegate) -> Bool {
            guard let mode = selected() else { return false }
            if mode != .supportDiagnostics {
                Diagnostics.storage = UserDefaults(suiteName: "app.orvlet.test-diagnostics")!
            }
            if mode.requiresLiveServices && !CommandLine.arguments.contains("--allow-live-services") {
                fputs("This check uses external services. Add --allow-live-services to opt in.\n", stderr)
                exit(2)
            }
            let model = delegate.model
            if mode == .modelPolicyProbe {
                Task { await ModelPolicyProbe.run(model) }
                return true
            }
            if mode == .cacheSizeCheck {
                model.isLiveTest = true
                model.persistHistory = false
                let weather =
                    (model.preferences.data(forKey: "sideTasks.v1").flatMap {
                        try? JSONDecoder().decode([SideTask].self, from: $0)
                    } ?? [])
                    .compactMap(\.taskSurface?.apiData).filter { $0.card?.kind == .weather }
                let result: [String: Any] = [
                    "weatherSources": weather.compactMap {
                        try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                    },
                    "home": NSHomeDirectory(), "cacheBytes": LocalDataSize.webCacheBytes() as Any? ?? "unavailable",
                ]
                print(JSONText.encode(result))
                exit(0)
            }
            if mode == .supportDiagnostics {
                if CommandLine.arguments.contains("--routing-context") {
                    // Explicit local inspection only; do not restore pages or mutate saved tasks.
                    model.isLiveTest = true
                    model.persistHistory = false
                    model.sideTasks =
                        model.preferences.data(forKey: "sideTasks.v1").flatMap {
                            try? JSONDecoder().decode([SideTask].self, from: $0)
                        } ?? []
                    print(
                        JSONText.encode([
                            "tasks": model.routingContext(explicit: nil),
                            "candidateIDs": JevRequestTriage.candidates(model, explicit: nil).map { $0.id.uuidString },
                        ]))
                    exit(0)
                }
                // Explicit local support export: bounded metadata only, no keys or page content.
                if CommandLine.arguments.contains("--last-pipeline-trace") {
                    let trace = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "orvlet-pipeline-live.jsonl")
                    print((try? String(contentsOf: trace, encoding: .utf8)) ?? "")
                } else {
                    print(Diagnostics.supportSummary())
                }
                exit(0)
            }
            if mode == .calendarCheck {
                Task { await CalendarCheck.run(model) }
                return true
            }
            if mode == .setupProbe {
                Task {
                    model.isLiveTest = true
                    let state = await model.calendarService.checkAccess(requestPermission: false)
                    if let data = try? JSONSerialization.data(
                        withJSONObject: [
                            "probeCompleted": true, "calendar": state.label, "ready": state == .ready,
                            "requestedPermission": false, "createdEvents": 0,
                            "detail": model.calendarService.lastAccessIssue ?? "",
                        ], options: .prettyPrinted)
                    {
                        try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
                    }
                    exit(0)
                }
                return true
            }
            if mode == .triageLiveCheck {
                Task { await RequestTriageCheck.live(model) }
                return true
            }
            if mode == .fastReuseLiveCheck {
                Task { await FastCardReuseCheck.live(model) }
                return true
            }
            if mode == .intentCheck {
                Task { await RequestRoutingCheck.live(model) }
                return true
            }
            if mode == .modelAPICheck {
                model.isLiveTest = true
                model.persistHistory = false
                Task { await ModelWireCheck.launch() }
                return true
            }
            if mode == .modelsPreview {
                Task { await ModelProfileCheck.preview(model) }
                return true
            }
            if mode == .selfCheck {
                Task { await SelfCheck.run(model: model) }
                return true
            }
            if mode == .localDataCheck {
                model.isLiveTest = true
                model.persistHistory = false
                Task { await LocalDataCheck.run() }
                return true
            }
            return false
        }
        static func afterWindows(_ delegate: AppDelegate) -> Bool {
            guard let mode = selected() else { return false }
            let model = delegate.model
            if mode == .taskContinuityCheck {
                Task { await TaskContinuityCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .requestPipelineLive {
                delegate.shortcut.unregister()
                delegate.statusItem.isVisible = false
                delegate.panel.ignoresMouseEvents = true
                model.onCommandPanel = nil
                Task {
                    if CommandLine.arguments.contains("--playback-restart") {
                        await PlaybackRestartCheck.live(model)
                    } else if CommandLine.arguments.contains("--background-read-benchmark") {
                        await BackgroundReadLiveCheck.run(model)
                    } else if CommandLine.arguments.contains("--playback-continuity") {
                        await PlaybackContinuityLiveCheck.run(model)
                    } else {
                        await RequestPipelineLiveCheck.run(model)
                    }
                }
                return true
            }
            if mode == .unifiedRequestLiveCheck {
                Task { await UnifiedRequestLiveCheck.run(model) }
                return true
            }
            if mode == .musicRequestCheck {
                Task { await MusicRequestCheck.run(model) }
                return true
            }
            if mode == .musicWorkflowCheck {
                Task { await MusicWorkflowCheck.run(model) }
                return true
            }
            if mode == .musicCheck || mode == .musicLiveCheck || mode == .musicSourceCheck {
                Task {
                    await MusicCheck.run(
                        model, delegate: delegate, live: mode != .musicCheck, sourceOnly: mode == .musicSourceCheck)
                }
                return true
            }
            if mode == .demoRecording {
                // A clean recording session uses the real UI/model, without showing or
                // saving the user's task history. No fixture answers or demo controls.
                model.isLiveTest = true
                model.persistHistory = false
                model.settings.autoAdapt = false
                model.settings.allowAgents = false
                model.settings.appearance = .light
                model.taskRuntime.stopAll()
                model.sideTasks = []
                model.messages = []
                model.archivedTaskHistory = []
                model.selectChat(true)
                return true
            }
            if mode == .builtinCardsCheck {
                Task { await BuiltinCardsCheck.start(model, delegate: delegate) }
                return true
            }
            if mode == .deliveryCheck || mode == .deliveryRestore || mode == .deliveryMedia || mode == .deliveryHistory
            {
                Task { await DeliveryCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .setupCheck {
                Task { await SetupCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .consistencyCheck {
                Task { await TaskConsistencyCheck.start() }
                return true
            }
            if mode == .taskHistoryCheck {
                Task { await TaskHistoryCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .interfaceCheck {
                InterfaceRevisionCheck.start()
                return true
            }
            if mode == .rankingLiveCheck {
                Task { await TaskRankingCheck.live(model) }
                return true
            }
            if mode == .taskAgentCheck {
                Task { await TaskAgentLiveCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .motionCheck {
                Task { await MotionCheck.start(model, delegate: delegate) }
                return true
            }
            if mode == .listeningCheck {
                Task { await ListeningCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .protectionCheck {
                Task { await ProtectionCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .commandWindowCheck {
                Task { await CommandWindowCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .workflowBenchmark {
                Task { await TaskAgentLiveCheck.benchmark(model, delegate: delegate) }
                return true
            }
            if mode == .apiDataCheck {
                Task { await APIDataCheck.live(model, delegate: delegate) }
                return true
            }
            if mode == .clockCheck {
                Task { await ClockCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .preparationCheck {
                model.isLiveTest = true
                model.persistHistory = false
                model.settings.autoAdapt = false
                model.settings.appearance = .light
                Task {
                    do {
                        let checks = try await PreparationCheck.run(model, delegate: delegate)
                        try JSONSerialization.data(
                            withJSONObject: ["ok": true, "checks": checks], options: .prettyPrinted
                        ).write(to: URL(fileURLWithPath: "/tmp/orvlet-preparation-checks.json"))
                        exit(0)
                    } catch {
                        try? JSONSerialization.data(
                            withJSONObject: ["ok": false, "error": error.localizedDescription], options: .prettyPrinted
                        ).write(to: URL(fileURLWithPath: "/tmp/orvlet-preparation-checks.json"))
                        exit(1)
                    }
                }
                return true
            }
            if mode == .sideScreenCheck {
                Task { await SideScreenCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .conversationCheck {
                Task { await ConversationCheck.run(model) }
                return true
            }
            if mode == .scenarioCheck {
                Task { await ScenarioCheck.run(model, delegate: delegate) }
                return true
            }
            if mode == .layoutCheck {
                Task { await LiveCheck.layout(model) }
                return true
            }
            if mode == .liveCheck {
                model.settings.allowAgents = false
                Task { await LiveCheck.run(model) }
                return true
            }
            return false
        }
    }
#endif
