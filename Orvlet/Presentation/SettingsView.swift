import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppSettings
    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        var settings = model.settings
        settings.ensureProfiles()
        _draft = State(initialValue: settings)
        _selectedTab = State(initialValue: initialTab)
        _connectionDetails = State(initialValue: !settings.main.isConfigured)
    }
    @State private var mainKey = ""
    @State private var fastKey = ""
    @State private var notice = ""
    @State private var modelNotice = ""
    @State private var mainResult = ""
    @State private var fastResult = ""
    @State private var testing = ""
    @State private var selectedTab = 0
    @State private var advancedJev = false
    @State private var savedKeyAccounts: Set<String> = []
    @State private var keyEdits: [String: String] = [:]
    @State private var connectionDetails = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { draft.appearance.scheme ?? systemScheme }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orvlet").font(.system(size: 23, weight: .medium, design: .rounded))
                    Text(model.settings.main.isConfigured ? "Settings" : "Connect your model")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 20)
            SettingsTabBar(selection: $selectedTab, accent: draft.theme.color, reducedMotion: model.motionReduced)
                .padding(.horizontal, 25).padding(.bottom, 16)
            // A fixed viewport owns the transition. Outgoing pages never participate
            // in a ScrollView's content sizing or push the tab bar out of position.
            ZStack(alignment: .top) {
                settingsPage.id(selectedTab).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(CalmMotion.animation(reduced: model.motionReduced), value: selectedTab)

        }.frame(width: 520, height: 710).tint(draft.theme.color)
            .background(CalmVisualStyle.windowFill(scheme))
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(draft.appearance.scheme)
            .onChange(of: draft.compactLayout) { _, _ in persistPreferences() }
            .onChange(of: draft.compactTaskLimit) { _, _ in persistPreferences() }
            .onChange(of: model.settings.appearance) { _, value in draft.appearance = value }
            .onChange(of: model.settings.theme) { _, value in draft.theme = value }
            .onChange(of: model.settings.compactLayout) { _, value in draft.compactLayout = value }
            .onChange(of: model.settings.compactTaskLimit) { _, value in draft.compactTaskLimit = value }
            .onAppear { model.settingsTabRequested = nil }
            .task(id: [draft.mainConnection.keyAccount, draft.fastKeyAccount]) {
                guard !model.isLiveTest else { return }
                for account in [draft.mainConnection.keyAccount, draft.fastKeyAccount] {
                    let value = try? await SecretStore.loadAvailable(account)
                    guard !Task.isCancelled else { return }
                    if let value, !value.isEmpty {
                        savedKeyAccounts.insert(account)
                    } else {
                        savedKeyAccounts.remove(account)
                    }
                }
                if !savedKeyAccounts.contains(draft.mainConnection.keyAccount) { connectionDetails = true }
            }
            .onChange(of: model.settingsTabRequested) { _, value in
                if let value {
                    selectedTab = value
                    model.settingsTabRequested = nil
                }
            }
            .onChange(of: draft.main) { _, _ in
                modelNotice = ""
                mainResult = ""
            }
            .onChange(of: draft.fast) { _, _ in modelNotice = "" }
            .onChange(of: draft.useFast) { _, _ in modelNotice = "" }
            .onChange(of: mainKey) { _, _ in modelNotice = "" }
            .onChange(of: fastKey) { _, _ in modelNotice = "" }
            .onChange(of: draft.theme) { _, _ in persistPreferences() }
            .onChange(of: draft.appearance) { _, _ in persistPreferences() }
            .onChange(of: draft.expandOnHover) { _, _ in persistPreferences() }
            .onChange(of: draft.reduceMotion) { _, _ in persistPreferences() }
            .onChange(of: draft.inactiveStackOpacity) { _, _ in persistPreferences() }
            .onChange(of: draft.blockAds) { _, _ in persistPreferences() }
            .onChange(of: draft.shortcut) { _, _ in persistPreferences() }
            .onChange(of: draft.taskStartPolicy) { _, _ in persistPreferences() }
            .onChange(of: draft.restoreLastSession) { _, _ in persistPreferences() }
            .onChange(of: draft.resumePlaybackOnLaunch) { _, _ in persistPreferences() }
            .onChange(of: draft.autoAdapt) { _, _ in persistPreferences() }

    }
    private var settingsPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 15) {
                    switch selectedTab {
                    case 0: general
                    case 1: appearance
                    case 2: intelligence
                    case 3: access
                    default: dataSettings
                    }
                }
                .padding(.horizontal, 25).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollIndicators(.automatic)
            if selectedTab == 2 {
                Divider().opacity(0.4)
                HStack(spacing: 12) {
                    Label(
                        modelNotice.isEmpty ? "Save to apply model changes" : modelNotice,
                        systemImage: modelNotice == "Saved" ? "checkmark.circle" : "lock"
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Save changes") { save() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(
                            !testing.isEmpty)
                }.padding(.horizontal, 25).padding(.vertical, 18)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    func persistPreferences() {
        let shortcutChanged = model.settings.shortcut != draft.shortcut
        model.setCompactLayout(draft.compactLayout)
        model.setCompactTaskLimit(draft.compactTaskLimit)
        model.settings.applyPreferences(from: draft)
        if !model.isLiveTest { model.settings.save() }
        if shortcutChanged { model.onShortcutChanged?() }
        model.refreshHover()
    }
    var general: some View {
        VStack(spacing: 15) {
            card {
                Text("Open Orvlet").font(.system(size: 13, weight: .medium))
                HStack {
                    Text("Keyboard shortcut")
                    Spacer()
                    Picker("Keyboard shortcut", selection: $draft.shortcut) {
                        ForEach(SummonShortcut.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                if model.shortcutStatus != "Ready" {
                    Text(model.shortcutStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                preferenceToggle("Expand on hover", value: $draft.expandOnHover)
            }
            card {
                Text("Tasks").font(.system(size: 13, weight: .medium))
                HStack {
                    Text("Start tasks")
                    Spacer()
                    Picker("Start tasks", selection: $draft.taskStartPolicy) {
                        ForEach(TaskStartPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }.help("Task first starts work immediately. Interface first prepares controls before playback.")
                preferenceToggle("Adapt controls automatically", value: $draft.autoAdapt)
                preferenceToggle("Block ads in built-in browser", value: $draft.blockAds)
                    .help("Reload a page after changing this setting. Some video ads may remain.")
                if let error = model.adBlockingError { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            card {
                Text("On launch").font(.system(size: 13, weight: .medium))
                preferenceToggle("Restore last session", value: $draft.restoreLastSession)
                preferenceToggle("Resume playback", value: $draft.resumePlaybackOnLaunch).disabled(
                    !draft.restoreLastSession)
            }
            Text("Changes are saved automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.toggleStyle(.switch).controlSize(.small)
    }
    var compactAppearance: some View {
        card {
            Text("Task cards").font(.system(size: 13, weight: .medium))
            Picker("Layout", selection: $draft.compactLayout) {
                ForEach(CompactLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Visible tasks").font(.system(size: 12))
                Slider(
                    value: Binding(
                        get: { Double(draft.compactTaskLimit) },
                        set: { draft.compactTaskLimit = Int($0.rounded()) }),
                    in: Double(
                        AppSettings.compactTaskLimits.lowerBound)...Double(AppSettings.compactTaskLimits.upperBound),
                    step: 1
                ).accessibilityLabel("Visible tasks")
                    .accessibilityValue("\(draft.compactTaskLimit)")
                Text("\(draft.compactTaskLimit)").font(.system(size: 11)).monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("When idle").font(.system(size: 12))
                Slider(value: $draft.inactiveStackOpacity, in: 0.1...1, step: 0.05).accessibilityLabel(
                    "Inactive stack opacity")
                Text("\(Int((draft.inactiveStackOpacity * 100).rounded()))%").font(.system(size: 11)).monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            if !model.taskOrder.isEmpty {
                Button("Use automatic order") { model.resetTaskOrder() }.font(.system(size: 11))
            }
        }
    }
    var intelligence: some View {
        VStack(spacing: 15) {
            card {
                HStack {
                    Label("Main model", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    badge("Required", color: draft.theme.color)
                }
                Text("Understands your requests, uses tools, and builds task interfaces.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Picker("Profile", selection: Binding(get: { draft.activeProfileID }, set: { switchProfile($0) })) {
                        ForEach(draft.profiles) { Text($0.name).tag($0.id) }
                    }.disabled(!testing.isEmpty)
                    Button {
                        rememberKeyEdit()
                        draft.addProfile()
                        mainKey = ""
                        mainResult = ""
                        connectionDetails = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless).disabled(!testing.isEmpty).help("Add profile").accessibilityLabel(
                        "Add profile")
                    testButton("main", title: "Test connection")
                }
                Text(draft.main.model.isEmpty ? "Add a model to get started." : draft.main.model).font(
                    .system(size: 11)
                ).foregroundStyle(.secondary)
                if !mainResult.isEmpty {
                    Text(mainResult).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Connection details", isExpanded: $connectionDetails) {
                    entry(
                        "Profile name", placeholder: "My model",
                        text: Binding(
                            get: { draft.profiles.first(where: { $0.id == draft.activeProfileID })?.name ?? "" },
                            set: { name in
                                if let i = draft.profiles.firstIndex(where: { $0.id == draft.activeProfileID }) {
                                    draft.profiles[i].name = name
                                    modelNotice = ""
                                }
                            }))
                    entry(
                        "Base URL", placeholder: "https://example.com/v1",
                        text: Binding(
                            get: { draft.main.baseURL },
                            set: { value in
                                let oldHost = draft.main.completionURL?.host
                                draft.main.baseURL = value
                                if oldHost != draft.main.completionURL?.host {
                                    mainKey = ""
                                    mainResult = ""
                                }
                            }))
                    entry("Model", placeholder: "Model ID from your provider", text: $draft.main.model)
                    if draft.main.options.authentication != .none {
                        keyEntry("API Key", value: $mainKey, account: draft.mainConnection.keyAccount)
                    }
                    ModelAdvancedSettings(endpoint: $draft.main)
                    Toggle(isOn: $draft.main.vision) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Supports images").font(.system(size: 12))
                            Text("For visual content that page structure cannot describe.").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch).controlSize(.small)
                    Text(
                        savedKeyAccounts.contains(draft.mainConnection.keyAccount)
                            ? "Tool calling is required. Leave the key blank to keep the saved key."
                            : "Tool calling is required. Save changes to use this connection."
                    ).font(.system(size: 11)).foregroundStyle(.secondary)
                    if draft.profiles.count > 1 {
                        Button("Remove profile", role: .destructive) {
                            let id = draft.activeProfileID
                            _ = draft.removeProfile(id)
                            mainKey = ""
                            mainResult = ""
                        }.font(.system(size: 11))
                    }
                }.font(.system(size: 12))
            }
            card {
                HStack {
                    Label("Jev", systemImage: "bolt").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    badge("Required", color: draft.theme.color)
                }
                Text(
                    "Routes requests and selects the capabilities needed. Clear actions can complete without an extra main-model call."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Group {
                    keyEntry("Jev API Key", value: $fastKey, account: draft.fastKeyAccount)
                    HStack {
                        testButton("fast", title: "Test Jev")
                        Text(fastResult).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    DisclosureGroup("Connection details", isExpanded: $advancedJev) {
                        entry(
                            "Jev Base URL", placeholder: "https://api.typesafe.ai/v1",
                            text: Binding(
                                get: { draft.fast.baseURL },
                                set: { value in
                                    let oldHost = draft.fast.completionURL?.host
                                    draft.fast.baseURL = value
                                    if oldHost != draft.fast.completionURL?.host {
                                        draft.fastCredentialID = UUID().uuidString
                                        fastKey = ""
                                        fastResult = ""
                                    }
                                }))
                        entry("Jev model", placeholder: "jev-latest", text: $draft.fast.model)
                    }.font(.system(size: 12))
                    Text(
                        "Uses brief eligible requests and anonymous task context. Obvious sensitive requests stay with your main model."
                    ).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(
                "Keys stay in Orvlet’s local data on this Mac. Page context is sent to your configured model when needed."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
        }
    }
    var appearance: some View {
        VStack(spacing: 15) {
            card {
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill").foregroundStyle(draft.theme.color)
                        Text("Orvlet").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).frame(width: 220, height: 36)
                        .background(draft.theme.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9).strokeBorder(
                                draft.theme.color.opacity(0.3), lineWidth: 0.5))
                    Spacer()
                }.padding(.vertical, 10)
                HStack(spacing: 18) {
                    ForEach(ThemeTone.allCases, id: \.self) { tone in
                        Button {
                            draft.theme = tone
                        } label: {
                            VStack(spacing: 8) {
                                Circle().fill(tone.color.gradient).frame(width: 31, height: 31)
                                    .overlay(
                                        Circle().strokeBorder(
                                            .primary.opacity(draft.theme == tone ? 0.8 : 0), lineWidth: 2
                                        ).padding(-4))
                                Text(tone.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).help(tone.title)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            card {
                Text("Appearance").font(.system(size: 13, weight: .medium))
                Picker("Appearance", selection: $draft.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Divider().padding(.vertical, 4)
                preferenceToggle("Reduce motion", value: $draft.reduceMotion)

            }
            compactAppearance
            Text("Changes are saved automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    var access: some View {
        VStack(spacing: 18) {
            SetupReadinessView(model: model, embedded: true)
            if model.settings.allowAgents && LocalBridge.browserPairingEnabled {
                card {
                    Text("Browser pairing").font(.system(size: 13, weight: .medium))
                    Text(
                        model.browserConnected
                            ? "Browser connected" : "Pair your browser or agent to use local connections."
                    ).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy pairing code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.bridge.token, forType: .string)
                            notice = "Pairing code copied"
                        }
                        .disabled(model.bridge.token.isEmpty)
                        if notice == "Pairing code copied" {
                            Text("Copied").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Use connected browser", isOn: $model.externalBrowser).disabled(!model.browserConnected)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }
    var dataSettings: some View {
        VStack(spacing: 15) {
            LocalDataSettingsView(model: model)
            card {
                Text("Troubleshooting").font(.system(size: 13, weight: .medium))
                Text("Diagnostics exclude conversation and page content.").font(.system(size: 11)).foregroundStyle(
                    .secondary)
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.supportSummary(), forType: .string)
                    notice = "Diagnostics copied"
                }
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    func preferenceToggle(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
        }
    }
    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(19).frame(
            maxWidth: .infinity, alignment: .leading
        )
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 19)).overlay(
            RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
    func badge(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(color).padding(.horizontal, 7).padding(
            .vertical, 4
        ).background(color.opacity(0.12), in: Capsule())
    }
    func entry(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(title)
        }
    }
    func keyEntry(_ title: String, value: Binding<String>, account: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            SecureField(
                savedKeyAccounts.contains(account) ? "Leave blank to keep saved key" : "Enter API key", text: value
            ).textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(title)
        }
    }
    func testButton(_ which: String, title: String) -> some View {
        Button {
            test(which)
        } label: {
            HStack(spacing: 6) {
                if testing == which { ProgressView().controlSize(.mini) }
                Text(testing == which ? "Connecting…" : title)
            }
        }.disabled(!testing.isEmpty || !(which == "main" ? draft.main.isConfigured : draft.fast.isConfigured))
            .controlSize(.small)
    }
    func rememberKeyEdit() {
        draft.storeActiveProfile()
        if !mainKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyEdits[draft.mainConnection.keyAccount] = mainKey
        }
    }
    func persistKeyEdits() throws {
        rememberKeyEdit()
        if model.isLiveTest { return }
        for (account, key) in keyEdits {
            try SecretStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            savedKeyAccounts.insert(account)
        }
        keyEdits = [:]
        mainKey = ""
    }
    func switchProfile(_ id: String) {
        rememberKeyEdit()
        guard draft.selectProfile(id) else { return }
        mainKey = keyEdits[draft.mainConnection.keyAccount] ?? ""
        mainResult = ""
        if !draft.main.isConfigured { connectionDetails = true }
        modelNotice = "Save to use this profile"
    }
    func save() {
        do {
            try draft.main.options.validate()
            for profile in draft.profiles where profile.id != draft.activeProfileID {
                try profile.endpoint.options.validate()
            }
            try persistKeyEdits()
            if !model.isLiveTest, !fastKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SecretStore.save(
                    fastKey.trimmingCharacters(in: .whitespacesAndNewlines), account: draft.fastKeyAccount)
                savedKeyAccounts.insert(draft.fastKeyAccount)
                fastKey = ""
            }
            draft.fastProtocol = "jev"
            model.settings.applyModels(from: draft)
            if !model.isLiveTest { model.settings.save() }
            modelNotice = "Saved"
            model.checkStartupReadiness()
        } catch { modelNotice = error.localizedDescription }
    }
    func test(_ which: String) {
        rememberKeyEdit()
        let connection =
            which == "main"
            ? draft.mainConnection : ModelConnection(endpoint: draft.fast, keyAccount: draft.fastKeyAccount)
        let enteredKey = which == "main" ? (keyEdits[connection.keyAccount] ?? "") : fastKey
        testing = which
        Task {
            defer { testing = "" }
            do {
                try connection.endpoint.options.validate()
                let key =
                    enteredKey.isEmpty
                    ? try await connection.loadKey() : enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if which == "main" {
                    let tool = ToolSchema.function(
                        "connection_check", "Confirm tool support", ["ok": ["type": "boolean"]], required: ["ok"])
                    let response = try await ModelClient.complete(
                        endpoint: connection.endpoint, key: key,
                        messages: [["role": "user", "content": "Call connection_check with ok=true."]], tools: [tool],
                        reasoning: false, requiredTool: "connection_check")
                    let raw = try StructuredResponse.arguments(response, named: "connection_check", allowJSON: false)
                    guard let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                        result["ok"] as? Bool == true
                    else { throw AppError.message("Connected, but the model did not confirm tool support.") }
                    if draft.main == connection.endpoint { mainResult = "Connected · tools supported" }
                } else {
                    let result = try await JevClient.judge(
                        endpoint: connection.endpoint, key: key, state: ["category": "audio", "playing": true],
                        questions: ["audio": "Is audio currently playing?"])
                    fastResult = result["audio"] == nil ? "Unexpected response format" : "Connected"
                }
            } catch {
                if which == "main", draft.main == connection.endpoint {
                    mainResult = error.localizedDescription
                } else if which == "fast", draft.fast == connection.endpoint {
                    fastResult = error.localizedDescription
                }
            }
        }
    }
}
