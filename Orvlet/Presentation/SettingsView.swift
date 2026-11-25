import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppSettings
    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        var settings = model.settings
        settings.ensureProfiles()
        settings.configureModelProvider()
        _draft = State(initialValue: settings)
        _selectedTab = State(initialValue: initialTab)
        _connectionDetails = State(initialValue: false)
    }
    @State private var mainKey = ""
    @State private var fastKey = ""
    @State private var notice = ""
    @State private var modelNotice = ""
    @State private var mainResult = ""
    @State private var fastResult = ""
    @State private var testing = ""
    @State private var selectedTab = 0
    @State private var advancedDecision = false
    @State private var savedKeyAccounts: Set<String> = []
    @State private var keyEdits: [String: String] = [:]
    @State private var connectionDetails = false
    @State private var optionHeld = false
    @State private var modifierMonitor: Any?
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
            .onAppear {
                model.settingsTabRequested = nil
                optionHeld = NSEvent.modifierFlags.contains(.option)
                if modifierMonitor == nil {
                    modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                        optionHeld = event.modifierFlags.contains(.option)
                        return event
                    }
                }
            }
            .onDisappear {
                if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
                modifierMonitor = nil
                optionHeld = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                optionHeld = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                optionHeld = NSEvent.modifierFlags.contains(.option)
            }
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
            }
            .onChange(of: model.settingsTabRequested) { _, value in
                if let value {
                    selectedTab = value
                    model.settingsTabRequested = nil
                }
            }
            .onChange(of: draft.main) { _, _ in
                if draft.main != draft.main.toolCompatible { draft.main = draft.main.toolCompatible }
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
            .onChange(of: draft.browserEngine) { _, _ in persistPreferences() }
            .onChange(of: draft.blockAds) { _, _ in persistPreferences() }
            .onChange(of: draft.interfaceLanguage) { _, _ in persistPreferences() }
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
                HStack {
                    Text("Generated interface language")
                    Spacer()
                    TextField("English", text: $draft.interfaceLanguage)
                        .accessibilityLabel("Generated interface language").frame(width: 150)
                }
                preferenceToggle("Adapt controls automatically", value: $draft.autoAdapt)
                if !NativeChromium.available {
                    preferenceToggle("Block ads in built-in browser", value: $draft.blockAds)
                        .help("Reload a page after changing this setting. Some video ads may remain.")
                }
                if let error = model.adBlockingError { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            card { SystemBrowserSettings(model: model, engine: $draft.browserEngine) }
            if draft.browserEngine == .builtIn, !NativeChromium.available, #available(macOS 15.4, *) {
                card { BrowserExtensionSettings(host: model.extensions, web: model.handoffSource?.webView ?? model.browser.webView) }
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
        VStack(spacing: 18) {
            Picker("Provider", selection: Binding(get: { draft.modelProvider }, set: switchProvider)) {
                ForEach(ModelProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().disabled(!testing.isEmpty)
            if draft.modelProvider == .gpt {
                card {
                    keyEntry("OpenAI API Key", value: $mainKey, account: draft.mainConnection.keyAccount)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("Model", selection: $draft.main.model) {
                            ForEach(gptModels, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    connectionTest("main")
                    if providerProfiles.count > 1 {
                        DisclosureGroup("Saved connections") { profilePicker }
                            .font(.system(size: 12))
                    }
                }
                Text("One key for your model and Decisions.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5)
            } else {
                card {
                    HStack {
                        Text("Main model").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if providerProfiles.count > 1 { profilePicker }
                        Button {
                            rememberKeyEdit()
                            draft.addProfile()
                            draft.configureModelProvider()
                            mainKey = ""; mainResult = ""
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless).help("Add connection").accessibilityLabel("Add connection")
                    }
                    entry("Base URL", placeholder: "https://example.com/v1", text: Binding(
                        get: { draft.main.baseURL }, set: { value in
                            rememberKeyEdit()
                            let oldHost = draft.main.completionURL?.host
                            draft.main.baseURL = value
                            if oldHost != draft.main.completionURL?.host { mainKey = ""; mainResult = "" }
                            draft.storeActiveProfile()
                        }))
                    entry("Model", placeholder: "Model ID", text: $draft.main.model)
                    if draft.main.options.authentication != .none {
                        keyEntry("API Key", value: $mainKey, account: draft.mainConnection.keyAccount)
                    }
                    connectionTest("main")
                    DisclosureGroup("Advanced", isExpanded: $connectionDetails) {
                        entry("Connection name", placeholder: "My model", text: Binding(
                            get: { draft.profiles.first(where: { $0.id == draft.activeProfileID })?.name ?? "" },
                            set: { name in
                                if let i = draft.profiles.firstIndex(where: { $0.id == draft.activeProfileID }) {
                                    draft.profiles[i].name = name
                                }
                            }))
                        ModelAdvancedSettings(endpoint: $draft.main)
                        Toggle("Supports images", isOn: $draft.main.vision).toggleStyle(.switch).controlSize(.small)
                        if providerProfiles.count > 1 {
                            Button("Remove connection", role: .destructive) { removeConnection() }.font(.system(size: 11))
                        }
                    }.font(.system(size: 12))
                }
                card {
                    Text("Jev").font(.system(size: 13, weight: .medium))
                    keyEntry("Jev API Key", value: $fastKey, account: draft.fastKeyAccount)
                    connectionTest("fast")
                    DisclosureGroup("Advanced", isExpanded: $advancedDecision) {
                        entry("Base URL", placeholder: DecisionAPI.jev.defaultEndpoint.baseURL, text: Binding(
                            get: { draft.fast.baseURL }, set: { value in
                                rememberKeyEdit()
                                let oldHost = draft.fast.completionURL?.host
                                draft.fast.baseURL = value
                                if oldHost != draft.fast.completionURL?.host {
                                    draft.fastCredentialID = UUID().uuidString
                                    draft.fastKeyReference = nil
                                    fastKey = ""; fastResult = ""
                                }
                            }))
                        entry("Model", placeholder: "jev-latest", text: $draft.fast.model)
                    }.font(.system(size: 12))
                }
            }
            if optionHeld && !SystemBrowserApplication.sandboxed {
                Button("Restore previous profiles…") { restorePreviousProfiles() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.disabled(!testing.isEmpty)
    }
    private var providerProfiles: [ModelProfile] {
        draft.profiles.filter { ModelProvider.provider(for: $0.endpoint) == draft.modelProvider }
    }
    private var gptModels: [String] {
        ModelProvider.gptModels + (ModelProvider.gptModels.contains(draft.main.model) ? [] : [draft.main.model])
    }
    private var profilePicker: some View {
        Picker("Connection", selection: Binding(get: { draft.activeProfileID }, set: switchProfile)) {
            ForEach(providerProfiles) { Text($0.name).tag($0.id) }
        }.labelsHidden().frame(maxWidth: 180).accessibilityLabel("Saved connection")
    }
    private func connectionTest(_ which: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            testButton(which, title: "Test connection")
            let result = which == "main" ? mainResult : fastResult
            if !result.isEmpty {
                Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func switchProvider(_ provider: ModelProvider) {
        rememberKeyEdit()
        draft.selectModelProvider(provider)
        mainKey = keyEdits[draft.mainConnection.keyAccount] ?? ""
        fastKey = keyEdits[draft.fastKeyAccount] ?? ""
        mainResult = ""; fastResult = ""; modelNotice = ""
        connectionDetails = false; advancedDecision = false
    }
    func removeConnection() {
        rememberKeyEdit()
        let next = providerProfiles.first { $0.id != draft.activeProfileID }?.id
        guard let next else { return }
        let removed = draft.activeProfileID
        _ = draft.selectProfile(next)
        _ = draft.removeProfile(removed)
        draft.configureModelProvider()
        mainKey = keyEdits[draft.mainConnection.keyAccount] ?? ""
        mainResult = ""
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
                savedKeyAccounts.contains(account) ? "Saved key — enter to replace" : "Enter API key", text: value
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
        if draft.decisionKeyReference == nil, !fastKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyEdits[draft.fastKeyAccount] = fastKey
        }
        if !mainKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyEdits[draft.mainConnection.keyAccount] = mainKey
        }
    }
    func restorePreviousProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Restore Orvlet profiles"
        panel.message = "Choose the previous Orvlet Library folder to restore model profiles and saved API keys. Existing saved keys are kept."
        panel.prompt = "Restore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ModelProfileRecovery.previousLibrary
        panel.begin { response in
            guard response == .OK, let library = panel.url else { return }
            let accessed = library.startAccessingSecurityScopedResource()
            defer { if accessed { library.stopAccessingSecurityScopedResource() } }
            do {
                // Validate the selected source before saving any pending model edits.
                let snapshot = try ModelProfileRecovery.read(library: library)
                try persistKeyEdits()
                if !fastKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try SecretStore.save(fastKey.trimmingCharacters(in: .whitespacesAndNewlines), account: draft.fastKeyAccount)
                    fastKey = ""
                }
                let result = try ModelProfileRecovery.restore(snapshot, into: draft, store: SecretStore.store)
                draft.applyModels(from: result.settings)
                model.settings.applyModels(from: result.settings)
                model.settings.save()
                savedKeyAccounts = result.savedAccounts
                mainKey = ""
                mainResult = ""
                fastResult = ""
                modelNotice = "Restored \(result.profiles) profiles and available saved keys."
                // Do not test providers or send recovered keys anywhere automatically.
            } catch { modelNotice = error.localizedDescription }
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
        fastKey = ""
    }
    func switchProfile(_ id: String) {
        rememberKeyEdit()
        guard draft.selectProfile(id) else { return }
        draft.configureModelProvider()
        fastKey = keyEdits[draft.fastKeyAccount] ?? ""
        mainKey = keyEdits[draft.mainConnection.keyAccount] ?? ""
        mainResult = ""
        modelNotice = "Save to use this profile"
    }
    func save() {
        do {
            rememberKeyEdit()
            draft.configureModelProvider()
            try draft.main.options.validate()
            for profile in draft.profiles where profile.id != draft.activeProfileID {
                try profile.endpoint.options.validate()
            }
            try persistKeyEdits()
            model.settings.applyModels(from: draft)
            if !model.isLiveTest { model.settings.save() }
            modelNotice = "Saved"
            model.checkStartupReadiness()
        } catch { modelNotice = error.localizedDescription }
    }
    func test(_ which: String) {
        rememberKeyEdit()
        draft.configureModelProvider()
        let connection =
            which == "main"
            ? draft.mainConnection : ModelConnection(endpoint: draft.fast, keyAccount: draft.fastKeyAccount)
        let enteredKey = keyEdits[connection.keyAccount] ?? ""
        let decisionAPI = draft.decisionAPI
        let combinedGPT = which == "main" && draft.modelProvider == .gpt
        let decisionEndpoint = draft.fast
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
                    if combinedGPT {
                        do {
                            let result = try await DecisionClient.judge(
                                endpoint: decisionEndpoint, api: .openAI, key: key,
                                state: ["category": "audio", "playing": true],
                                questions: ["audio": "Is audio currently playing?"])
                            guard result["audio"] != nil else { throw AppError.message("Unexpected Decisions response") }
                            if draft.main == connection.endpoint { mainResult = "Connected · model and Decisions" }
                        } catch {
                            if draft.main == connection.endpoint {
                                mainResult = "Model connected. Decisions: " + error.localizedDescription
                            }
                        }
                    } else if draft.main == connection.endpoint { mainResult = "Connected · tools supported" }
                } else {
                    let result = try await DecisionClient.judge(
                        endpoint: connection.endpoint, api: decisionAPI, key: key, state: ["category": "audio", "playing": true],
                        questions: ["audio": "Is audio currently playing?"])
                    if draft.fast == connection.endpoint && draft.decisionAPI == decisionAPI {
                        fastResult = result["audio"] == nil ? "Unexpected response format" : "Connected"
                    }
                }
            } catch {
                if which == "main", draft.main == connection.endpoint {
                    mainResult = error.localizedDescription
                } else if which == "fast", draft.fast == connection.endpoint, draft.decisionAPI == decisionAPI {
                    fastResult = error.localizedDescription
                }
            }
        }
    }
}
