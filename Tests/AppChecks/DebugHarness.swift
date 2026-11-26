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
            case generativeLatency = "--generative-latency"
            case stateMachineCheck = "--state-machine-check"
            case memoryCheck = "--memory-check"
            case systemBrowserCheck = "--system-browser-check"
            case nativeBrowserCheck = "--native-browser-check"
            case consistencyCheck = "--consistency-check"
            case taskHistoryCheck = "--task-history-check"
            case interfaceCheck = "--interface-check"
            case rankingLiveCheck = "--ranking-live-check"
            case taskAgentCheck = "--task-agent-check"
            case motionCheck = "--motion-check"
            case sourceWindowCheck = "--source-window-check"
            case generationRecoveryCheck = "--generation-recovery-check"
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
            case backgroundReadingCheck = "--background-reading-check"
            case dataReadingCheck = "--data-reading-check"
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
                case .generativeLatency, .modelPolicyProbe, .requestPipelineLive, .calendarCheck, .triageLiveCheck, .fastReuseLiveCheck,
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
        static func startStandalonePilot() -> Bool {
            guard CommandLine.arguments.contains("--pilot-replay") else { return false }
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return true
        }
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
            if let index = CommandLine.arguments.firstIndex(of: "--test-model-profile"), index + 1 < CommandLine.arguments.count {
                let profile = CommandLine.arguments[index + 1]
                guard model.settings.selectProfile(profile) else { fputs("Unknown test model profile\n",stderr); exit(2) }
                // In-memory only. Never save or change the desktop connection.
            }
            if CommandLine.arguments.contains("--test-reasoning-none") {
                model.settings.main.options.reasoning = .none
                var parameters = (try? model.settings.main.options.object(model.settings.main.options.parameters, label:"Test parameters")) ?? [:]
                parameters["reasoning_effort"] = "none"
                model.settings.main.options.parameters = JSONText.encode(parameters)
            }
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
            if CommandLine.arguments.contains("--background-checks"), mode != .stateMachineCheck && mode != .memoryCheck && mode != .modelAPICheck && mode != .systemBrowserCheck && mode != .nativeBrowserCheck && mode != .generativeLatency {
                fputs("This suite may show windows. It cannot run in background-check mode.\n", stderr)
                exit(2)
            }
            if mode == .generativeLatency {
                guard CommandLine.arguments.contains("--background-checks") else { exit(2) }
                Task { await GenerativeLatencyCheck.run() }
                return true
            }
            if mode == .systemBrowserCheck {
                Task { await SystemBrowserCheck.start() }
                return true
            }
            if mode == .nativeBrowserCheck {
                Task { await NativeChromiumCheck.start() }
                return true
            }
            if mode == .stateMachineCheck {
                Task { await StateMachineCheck.start() }
                return true
            }
            if mode == .memoryCheck {
                Task { await MemoryCheck.start() }
                return true
            }
            let model = delegate.model
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--audit-work-store") {
                let saved = WorkRepository(defaults:.standard).snapshot
                if CommandLine.arguments.contains("--remove-audited-fixture") {
                    // Only the one unowned fixture created before test-store isolation.
                    guard saved.goals.isEmpty, saved.attempts.isEmpty, saved.artifacts.count == 1,
                        let fixture = saved.artifacts.values.first, fixture.title == "Currency conversion",
                        fixture.goalID == nil, fixture.native == nil, fixture.source == nil,
                        fixture.values["converted"] != nil else { print("Refused: store is not the audited fixture"); exit(1) }
                    UserDefaults.standard.removeObject(forKey:"work.v1")
                    UserDefaults.standard.synchronize()
                    print("Removed isolated-check residue; other preferences unchanged")
                    exit(0)
                }
                print(JSONText.encode(["goals":saved.goals.count,"artifacts":saved.artifacts.values.map {
                    ["title":$0.title,"source":$0.source ?? "","hasGoal":$0.goalID != nil] as [String:Any]
                }]))
                exit(0)
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--diagnose-models") {
                print(JSONText.encode(["main":model.settings.main.model, "profiles":model.settings.profiles.map { ["id":$0.id,"model":$0.endpoint.model,"host":$0.endpoint.completionURL?.host ?? ""] }]))
                exit(0)
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--probe-selected-model") {
                Task {
                    do {
                        let connection = model.settings.mainConnection
                        let schema = ToolSchema.function("ready", "Report readiness", ["ok":["type":"boolean"]], required:["ok"])
                        _ = try await ModelClient.complete(endpoint: connection.endpoint, key: connection.loadKey(),
                            messages: [["role":"user","content":"Call ready with ok=true."]], tools: [schema],
                            reasoning:false, requiredTool:"ready", maximumWait:12)
                        print(JSONText.encode(["model":connection.endpoint.model,"ok":true])); exit(0)
                    } catch { print(JSONText.encode(["model":model.settings.main.model,"error":error.localizedDescription])); exit(1) }
                }
                return true
            }
            if mode == .protectionCheck, CommandLine.arguments.contains("--task-dismissal") {
                Task {
                    do { try await TaskDismissalCheck.run(); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .protectionCheck, CommandLine.arguments.contains("--playback-handoff") {
                Task {
                    do { try await PlaybackHandoffCheck.run(model); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .protectionCheck, CommandLine.arguments.contains("--ads-only") {
                model.isLiveTest = true
                model.persistHistory = false
                Task {
                    do {
                        try await ProtectionCheck.checkAds(model) { passed, name in
                            guard passed else { throw AppError.message(name) }
                            print(name)
                        }
                        exit(0)
                    } catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--verify-credentials") {
                Task {
                    do { print(JSONText.encode(["checks": try await LocalCredentialsCheck.run()])); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, let index = CommandLine.arguments.firstIndex(of: "--check-saved-reading"), index + 1 < CommandLine.arguments.count {
                Task {
                    do { try await ParallelCardsCheck.checkSavedReading(model, subject: CommandLine.arguments[index + 1]); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, ["--verify-scopes", "--verify-source-join", "--verify-calculated-answer"].contains(where: CommandLine.arguments.contains) {
                Task {
                    defer { if let suite = pipelineSuite { model.preferences.removePersistentDomain(forName: suite) } }
                    do { try await ParallelCardsCheck.verifyEdgeRequest(model, join: CommandLine.arguments.contains("--verify-source-join")); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--verify-site-browser") {
                Task {
                    do { try await BrowserCompatibilityCheck.run(model); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, let i = CommandLine.arguments.firstIndex(of: "--verify-placement"),
                let scenario = CommandLine.arguments.dropFirst(i + 1).first {
                Task {
                    do { try await ParallelCardsCheck.verifyPlacement(model, scenario: scenario) }
                    catch { print(error.localizedDescription); exit(1) }
                    if let suite = pipelineSuite { model.preferences.removePersistentDomain(forName: suite) }
                    exit(0)
                }
                return true
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--verify-work-separation") {
                Task {
                    do { try await WorkSeparationCheck.run(model); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, CommandLine.arguments.contains("--verify-comparison") {
                Task {
                    defer { if let suite = pipelineSuite { model.preferences.removePersistentDomain(forName: suite) } }
                    do { try await ParallelCardsCheck.verifyComparison(model); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive, let i = CommandLine.arguments.firstIndex(of: "--verify-readings") {
                Task {
                    defer { if let suite = pipelineSuite { model.preferences.removePersistentDomain(forName: suite) } }
                    do { try await ParallelCardsCheck.verifyReadings(model, cases: CommandLine.arguments.suffix(from: i + 1)); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive && CommandLine.arguments.contains("--parallel-cards") {
                Task {
                    defer { if let suite = pipelineSuite { model.preferences.removePersistentDomain(forName: suite) } }
                    do { try await ParallelCardsCheck.run(model); exit(0) }
                    catch { print(error.localizedDescription); exit(1) }
                }
                return true
            }
            if mode == .requestPipelineLive && CommandLine.arguments.contains("--continuation-study") {
                Task { await ContinuationStudy.run(model, delegate: delegate) }
                return true
            }
            if mode == .requestPipelineLive && CommandLine.arguments.contains("--pilot-export-trace") {
                for name in ["deduplicate", "countdown", "bill"] {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("simple-pilot-\(name).jsonl")
                    SimpleTaskPilot.emit(["traceName": name, "trace": (try? String(contentsOf: url, encoding: .utf8)) ?? "", "path": url.path])
                }
                exit(0)
            }
            if mode == .requestPipelineLive && CommandLine.arguments.contains("--simple-task-pilot") {
                Task { await SimpleTaskPilot.run(model, delegate: delegate) }
                return true
            }
            if mode == .generationRecoveryCheck {
                Task {
                    do {
                        var checks = try await GenerationRecoveryCheck.run()
                        if !CommandLine.arguments.contains("--generation-only") {
                            checks += try await UnifiedRequestCheck.run() + RequestBoundaryCheck.run()
                        }
                        print(JSONText.encode(["ok": true, "checks": checks]))
                        if CommandLine.arguments.contains("--stdout") { exit(0) }
                        try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(
                            to: URL(fileURLWithPath: "/tmp/orvlet-generation-checks.json"))
                        exit(0)
                    } catch {
                        print(JSONText.encode(["ok": false, "error": error.localizedDescription]))
                        try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])
                            .write(to: URL(fileURLWithPath: "/tmp/orvlet-generation-checks.json"))
                        exit(1)
                    }
                }
                return true
            }
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
                    if CommandLine.arguments.contains("--simple-task-pilot") {
                        await SimpleTaskPilot.run(model, delegate: delegate)
                    } else if CommandLine.arguments.contains("--playback-restart") {
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
            if mode == .motionCheck || mode == .sourceWindowCheck {
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
            if mode == .backgroundReadingCheck || mode == .dataReadingCheck {
                Task {
                    do {
                        let checks = mode == .dataReadingCheck ? try await APIDataCheck.run() : try await APIDataCheck.backgroundReading()
                        let report: [String: Any] = ["checks": checks, "ok": true]
                        if mode == .dataReadingCheck && !CommandLine.arguments.contains("--report-stdout") {
                            try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: "/tmp/orvlet-reading-checks.json"))
                        }
                        print(JSONText.encode(report))
                        exit(0)
                    } catch {
                        print(error.localizedDescription)
                        exit(1)
                    }
                }
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
