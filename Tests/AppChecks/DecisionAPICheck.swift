#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DecisionAPICheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { try StateMachineCheck.require(value, label, &checks) }
        func rejects(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
        let language = AppSettings().interfaceLanguageInstruction
        let playback = AgentPrompts.execution(families: ["music"], languageInstruction: language)
        let generated = AgentPrompts.execution(families: ["music", "workspace"], languageInstruction: language)
        try check(!playback.contains(CalmVisualStyle.taskHierarchy) && generated.contains(CalmVisualStyle.taskHierarchy)
            && [playback, generated].allSatisfy { $0.components(separatedBy: language).count == 2 },
            "Loading a design capability adds the card contract to a music turn and preserves a single language preference")
        var player = SideTask(kind: .web, title: "Night music")
        player.listening = true
        player.musicSessionRole = .shared
        var independentPlayer = SideTask(kind: .web, title: "Second session")
        independentPlayer.listening = true
        independentPlayer.musicSessionRole = .independent
        let video = SideTask(kind: .web, title: "Lecture", listening: true)
        let tasks = [player, independentPlayer, video]
        let routing = JevRequestTriage.request(text: "Change the track", candidates: tasks, explicit: nil)
        let candidates = routing.state["candidates"] as? [[String: Any]] ?? []
        let activities = candidates.compactMap { $0["activity"] as? String }
        try check(activities == ["music player", "independent music player", "media playback"]
            && candidates.allSatisfy { $0["playing"] as? Bool == false && $0["purpose"] == nil }
            && tasks.allSatisfy { !JSONText.encode(routing.state).contains($0.id.uuidString) },
            "Routing distinguishes paused players and ordinary video without absent purpose or persistent identifiers")
        let official = Endpoint(baseURL: "https://api.openai.com/v1", model: "gpt-6.2-sol")
        try check(official.toolCompatible.completionURL?.path == "/v1/responses", "Official GPT-6 tools use Responses before any network call")
        var custom = official
        custom.baseURL = "https://gateway.example/v1"
        try check(custom.toolCompatible == custom, "OpenAI compatibility repair does not rewrite other providers")
        custom = official; custom.options.exactURL = true
        try check(custom.toolCompatible == custom, "An explicitly pinned URL is never silently changed")
        custom = official; custom.model = "gpt-4.1"
        try check(custom.toolCompatible == custom, "Existing compatible Chat Completions models keep their protocol")
        let tool = ToolSchema.function("connection_check", "Check", ["ok": ["type": "boolean"]], required: ["ok"])
        let body = try ModelWire.body(endpoint: official.toolCompatible, messages: [["role":"user","content":"Check"]], tools: [tool], reasoning: false, requiredTool: "connection_check", budget: .low)
        try check((body["reasoning"] as? [String: String])?["effort"] == "low" && body["reasoning_effort"] == nil && body["messages"] == nil && body["input"] != nil,
                  "GPT-6 connection checks retain supported reasoning and the Responses tool envelope")
        let ordinary = try ModelWire.body(endpoint: official.toolCompatible, messages: [["role":"user","content":"Plan"]], tools: [tool], reasoning: true, requiredTool: nil, budget: .standard)
        try check(ordinary["reasoning"] == nil, "Ordinary GPT requests retain the provider's reasoning default")
        var overridden = official
        overridden.options.parameters = #"{"reasoning_effort":"high","max_completion_tokens":2048}"#
        let converted = try overridden.toolCompatible.options.object(overridden.toolCompatible.options.parameters, label: "Parameters")
        try check((converted["reasoning"] as? [String: String])?["effort"] == "high" && converted["max_output_tokens"] as? Int == 2048 && converted["reasoning_effort"] == nil,
                  "GPT protocol migration translates explicit reasoning and token overrides without lowering them")
        var settings = AppSettings()
        settings.main = official
        settings.ensureProfiles()
        settings.profiles[0].name = "GPT"
        let mainAccount = settings.mainConnection.keyAccount
        let jevAccount = settings.fastKeyAccount
        settings.selectDecisionAPI(.openAI)
        try check(settings.main.options.api == .responses && settings.mainConnection.keyAccount == mainAccount,
                  "Migrating GPT profiles keeps the credential reference intact")
        try check(settings.fast.model == "gpt-6-luna" && settings.fastKeyAccount == mainAccount,
                  "OpenAI Decisions reuses the existing OpenAI key without reading or copying it")
        settings.selectDecisionAPI(.jev)
        try check(settings.fastKeyAccount == jevAccount && settings.fast.model == "jev-latest", "Switching back to Jev preserves its original saved key")
        settings.selectDecisionAPI(.openAI)
        settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        try check(settings.decisionAPI == .openAI && settings.fastKeyAccount == mainAccount, "Decision provider and shared credential reference survive restart")
        settings.fast.baseURL = "https://untrusted.example/v1"
        try check(settings.decisionKeyReference == nil && settings.fastKeyAccount != mainAccount,
                  "A changed decision host cannot receive a reused OpenAI credential")
        try check(!DecisionAPI.openAI.allowsBackground(settings.fast) && DecisionAPI.openAI.allowsBackground(DecisionAPI.openAI.defaultEndpoint),
                  "Background decision contexts go only to the selected approved provider")
        var endpoint = Endpoint(baseURL: "http://127.0.0.1:19244/api-wire/decision/v1", model: "gpt-6-luna")
        let predicates: [String: Any] = ["audio": ["type": "noul", "instructions": "Is audio playing?"]]
        let openBody = try DecisionClient.body(endpoint: endpoint, api: .openAI, state: ["playing":true], questions: predicates)
        try check(openBody["state"] == nil && (openBody["questions"] as? [[String: Any]])?.first?["type"] as? String == "predicate",
                  "OpenAI Decisions uses typed predicate questions and structured evidence")
        let openResult = try await DecisionClient.judge(endpoint: endpoint, api: .openAI, key: "TEST_DECISION_KEY", state: ["playing":true], questions: ["audio":"Is audio playing?"])
        try check(openResult["audio"] == 0.95, "OpenAI Decisions completes an HTTP predicate request using its own endpoint and response shape")
        endpoint.model = "jev-latest"
        let jevResult = try await DecisionClient.judge(endpoint: endpoint, api: .jev, key: "TEST_DECISION_KEY", state: ["playing":true], questions: ["audio":"Is audio playing?"])
        try check(jevResult["audio"] == 0.95, "Jev still completes its existing systemone contract")
        endpoint.model = "gpt-6-luna"
        let triage = try await JevRequestTriage.judge(text: "Play music", candidates: [], explicit: nil, endpoint: endpoint, key: "TEST_DECISION_KEY", api: .openAI)
        try check(triage.routeKnown && triage.target == nil && !triage.additionalInstance,
                  "OpenAI choice distributions drive the existing guarded task routing")
        let choiceQuestions: [String: Any] = ["route": ["type":"choice", "instructions":"Choose", "criteria":["new":"New", "unsure":"Uncertain"]]]
        let incomplete: [String: Any] = ["name":"route", "type":"choice", "choice":"new", "confidence":1, "probabilities":[["value":"new","probability":1]]]
        try check(rejects { _ = try DecisionClient.normalize(["answers":[incomplete]], api: .openAI, questions: choiceQuestions) },
                  "Incomplete choice distributions cannot resolve task ownership")
        let unknown: [String: Any] = ["name":"unexpected", "type":"predicate", "probability":0.9]
        try check(rejects { _ = try DecisionClient.normalize(["answers":[unknown]], api: .openAI, questions: predicates) },
                  "Unrequested decision answers are rejected")
        var independent = settings
        independent.fastKeyReference = nil
        independent.fastCredentialID = "openai-fixture-slot"
        let independentAccount = independent.fastKeyAccount
        independent.selectDecisionAPI(.jev); independent.selectDecisionAPI(.openAI)
        try check(independent.fastKeyReference == nil && independent.fastKeyAccount == independentAccount,
                  "A separately configured decision key survives provider round trips")
        let refused = try DecisionClient.normalize(["answers":[["name":"audio","type":"refusal"]]], api: .openAI, questions: predicates)
        try check((refused["answers"] as? [String: Any])?.isEmpty == true, "Decision refusals never become confident actions")
        for value in [true, -0.1, 1.1, "0.9"] as [Any] {
            try check(rejects { _ = try DecisionClient.normalize(["answers":[["name":"audio","type":"predicate","probability":value]]], api: .openAI, questions: predicates) },
                      "Invalid decision probability rejected: \(String(describing: type(of: value))) \(value)")
        }
        let good: [String: Any] = ["name":"audio","type":"predicate","probability":0.9]
        try check(rejects { _ = try DecisionClient.normalize(["answers":[good,good]], api: .openAI, questions: predicates) }, "Duplicate decision answers are rejected")
        endpoint.baseURL = "https://api.openai.com/v1/decisions?region=example"
        try check(DecisionAPI.openAI.url(for: endpoint)?.absoluteString == endpoint.baseURL, "Decision endpoint paths are not duplicated and queries are preserved")
        var credentialURL = URLComponents(string: "https://api.openai.com/v1")!
        credentialURL.user = "fixture-user"; credentialURL.password = "fixture-password"
        endpoint.baseURL = credentialURL.string!
        try check(DecisionAPI.openAI.url(for: endpoint) == nil, "Decision URLs reject embedded credentials")
        var modes = AppSettings()
        modes.main = Endpoint(baseURL: "https://custom.example/v1", model: "original-model")
        modes.ensureProfiles()
        let originalID = modes.activeProfileID
        let originalKey = modes.mainConnection.keyAccount
        let originalJevKey = modes.fastKeyAccount
        modes.fast.model = "my-jev-model"
        modes.selectModelProvider(.gpt)
        let gptID = modes.activeProfileID
        let gptKey = modes.mainConnection.keyAccount
        try check(modes.profiles.count == 2 && modes.main.options.api == .responses && modes.main.vision,
            "GPT mode creates a tool-capable connection without replacing the existing custom profile")
        try check(modes.fastKeyAccount == gptKey && modes.decisionAPI == .openAI && modes.fast.model == "gpt-6-luna",
            "GPT mode binds the main model and Decisions to a single credential account")
        modes.main.model = "gpt-6.2-astra"
        modes.configureModelProvider()
        try check(modes.mainConnection.keyAccount == gptKey && modes.fastKeyAccount == gptKey,
            "Choosing another GPT model keeps the same key for both services")
        modes.selectModelProvider(.custom)
        try check(modes.activeProfileID == originalID && modes.mainConnection.keyAccount == originalKey && modes.main.model == "original-model",
            "Returning to Custom restores the original provider, model and key reference")
        try check(modes.decisionAPI == .jev && modes.fastKeyAccount == originalJevKey && modes.fast.model == "my-jev-model",
            "Custom restores the existing Jev settings and legacy key account")
        modes.addProfile()
        modes.main = Endpoint(baseURL: "https://second.example/v1", model: "second-model")
        modes.configureModelProvider()
        let secondID = modes.activeProfileID
        modes.selectModelProvider(.gpt)
        try check(modes.activeProfileID == gptID && modes.main.model == "gpt-6.2-astra" && modes.profiles.count == 3,
            "Repeated provider switching reuses the selected GPT profile instead of duplicating it")
        modes = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(modes))
        modes.selectModelProvider(.custom)
        try check(modes.activeProfileID == secondID && modes.main.model == "second-model",
            "The last custom connection survives provider switching and an app restart")
        let snapshot = modes
        modes.selectModelProvider(.gpt)
        modes.selectModelProvider(.custom)
        try check(modes.profiles.map(\.keyAccount) == snapshot.profiles.map(\.keyAccount),
            "Switching modes preserves every saved credential reference")
        var gateway = official
        gateway.baseURL = "https://gateway.example/v1"
        try check(ModelProvider.provider(for: gateway) == .custom, "GPT models behind third-party gateways remain Custom connections")
        gateway = official; gateway.options.exactURL = true
        try check(ModelProvider.provider(for: gateway) == .custom, "Explicit endpoint integrations remain editable in Custom")
        var applied = AppSettings()
        applied.applyModels(from: modes)
        try check(applied.preferredModelProfiles == modes.preferredModelProfiles,
            "Saving the model page retains the mode-specific selected connections")
        checks += try ModelProfileCheck.run()
        return checks
    }
    static func render() async throws -> [String] {
        let suite = "orvlet-decision-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true; model.persistHistory = false
        model.settings = AppSettings()
        model.settings.main = Endpoint(baseURL: "https://api.openai.com/v1", model: "gpt-6.2-sol")
        model.settings.ensureProfiles()
        model.settings.profiles[0].name = "GPT"
        for provider in ModelProvider.allCases {
            model.settings.selectModelProvider(provider)
            if provider == .custom {
                model.settings.main = Endpoint(baseURL: "https://example.com/v1", model: "my-model")
                model.settings.storeActiveProfile()
            }
            for dark in [false, true] {
                model.settings.appearance = dark ? .dark : .light
                let view = NSHostingView(rootView: SettingsView(model: model, initialTab: 2))
                let window = NSPanel(contentRect: NSRect(x: -18000, y: -18000, width: 520, height: 710), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderBack(nil)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-models-\(provider.rawValue)-\(dark ? "dark" : "light").png")
                window.orderOut(nil)
            }
        }
        return ["Complete GPT and Custom settings pages render offscreen at production size in both appearances without activation"]
    }
}
#endif
