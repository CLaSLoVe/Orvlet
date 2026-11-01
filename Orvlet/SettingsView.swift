import SwiftUI
import Security
import WebKit

struct Endpoint: Codable {
    var baseURL = ""
    var model = ""
    var vision = false
    var isConfigured: Bool { completionURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var completionURL: URL? {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: text), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        return text.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }
}
enum ThemeTone: String, Codable, CaseIterable {
    case iris, mint, peach, sky, rose, stone
    var title: String {
        switch self { case .iris: "Iris"; case .mint: "Mint"; case .peach: "Peach"; case .sky: "Sky"; case .rose: "Rose"; case .stone: "Stone" }
    }
    var color: Color {
        let value = UInt64(hex.dropFirst(),radix:16) ?? 0xa49bdf
        return Color(red:Double((value >> 16) & 255)/255,green:Double((value >> 8) & 255)/255,blue:Double(value & 255)/255)
    }
}
enum AppAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}
enum CompactLayout: String, Codable, CaseIterable {
    case vertical, horizontal
    var title: String { self == .vertical ? "Vertical" : "Horizontal" }
}
struct ModelSettings: Codable {
    var compactLayout = CompactLayout.vertical
    var inactiveStackOpacity = 0.55
    var blockAds = true
    var shortcut = SummonShortcut.optionSpace
    var main = Endpoint()
    var fast = Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
    var fastProtocol = "jev"
    var useFast = false
    var autoAdapt = true
    var allowAgents = false
    var theme = ThemeTone.iris
    var appearance = AppAppearance.dark
    var reduceMotion = false
    var expandOnHover = false
    var restoreLastSession = true
    var resumePlaybackOnLaunch = false
    init() {}
    enum CodingKeys: String, CodingKey { case compactLayout, inactiveStackOpacity, blockAds, shortcut, main, fast, fastProtocol, useFast, autoAdapt, allowAgents, theme, appearance, reduceMotion, expandOnHover, restoreLastSession, resumePlaybackOnLaunch }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compactLayout = try c.decodeIfPresent(CompactLayout.self, forKey:.compactLayout) ?? .vertical
        inactiveStackOpacity = min(1,max(0.1,try c.decodeIfPresent(Double.self,forKey:.inactiveStackOpacity) ?? 0.55))
        blockAds = try c.decodeIfPresent(Bool.self,forKey:.blockAds) ?? true
        shortcut = try c.decodeIfPresent(SummonShortcut.self, forKey:.shortcut) ?? .optionSpace
        main = try c.decodeIfPresent(Endpoint.self, forKey: .main) ?? Endpoint()
        fast = try c.decodeIfPresent(Endpoint.self, forKey: .fast) ?? Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
        fastProtocol = try c.decodeIfPresent(String.self, forKey: .fastProtocol) ?? "jev"
        useFast = try c.decodeIfPresent(Bool.self, forKey: .useFast) ?? false
        autoAdapt = try c.decodeIfPresent(Bool.self, forKey: .autoAdapt) ?? true
        allowAgents = try c.decodeIfPresent(Bool.self, forKey: .allowAgents) ?? false
        theme = try c.decodeIfPresent(ThemeTone.self, forKey: .theme) ?? .iris
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        expandOnHover = try c.decodeIfPresent(Bool.self, forKey: .expandOnHover) ?? false
        restoreLastSession = try c.decodeIfPresent(Bool.self, forKey:.restoreLastSession) ?? true
        resumePlaybackOnLaunch = try c.decodeIfPresent(Bool.self, forKey:.resumePlaybackOnLaunch) ?? false
    }
    static func load() -> ModelSettings {
        guard let data = UserDefaults.standard.data(forKey: "modelSettings"), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "modelSettings") } }
}
nonisolated enum SecretStore {
    static func load(_ account: String) async throws -> String {
        // Keychain may show an OS permission prompt; never block animation or the main thread.
        try await Task.detached { try read(account) }.value
    }
    private static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.orvlet.desktop", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else { throw AgentError.message("Allow Keychain access, then try again.") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.orvlet.desktop", kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Unable to update Keychain.") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AgentError.message("Unable to save the key. Check Keychain permissions.") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PetModel
    @State private var draft = ModelSettings.load()
    @State private var mainKey = ""
    @State private var fastKey = ""
    @State private var notice = ""
    @State private var mainResult = ""
    @State private var fastResult = ""
    @State private var testing = ""
    @State private var selectedTab = 0
    @State private var advancedJev = false
    @State private var credentialsReady = false
    @Environment(\.dismiss) private var dismiss
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
            Picker("Settings", selection: $selectedTab) {
                Text("General").tag(0); Text("Appearance").tag(1); Text("Models").tag(2); Text("Advanced").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 25).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 15) {
                    if selectedTab == 0 { general }
                    else if selectedTab == 1 { appearance }
                    else if selectedTab == 2 { intelligence }
                    else { connections }
                }.padding(.horizontal, 25).padding(.bottom, 18)
            }.scrollIndicators(.hidden)
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Label(notice.isEmpty ? "Saved on this Mac" : notice, systemImage: notice == "Saved" ? "checkmark.circle" : "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(model.settings.main.isConfigured ? "Save" : "Save & start") { save() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(!credentialsReady)
            }.padding(.horizontal, 25).padding(.vertical, 18)
        }.frame(width: 520, height: 710).tint(draft.theme.color)
            .preferredColorScheme(draft.appearance.scheme)
            .task {
                if model.isLiveTest { credentialsReady = true; return }
                do {
                    mainKey = try await SecretStore.load("main")
                    credentialsReady = true
                } catch { notice = error.localizedDescription }
            }
            .onChange(of: draft.compactLayout) { _, value in model.setCompactLayout(value) }
            .onChange(of: model.settings.compactLayout) { _, value in draft.compactLayout = value }
            .onAppear { draft.compactLayout = model.settings.compactLayout }
            .onChange(of: draft.theme) { _, value in model.settings.theme = value }
            .onChange(of: draft.appearance) { _, value in model.settings.appearance = value }
            .onChange(of: draft.expandOnHover) { _, value in model.settings.expandOnHover = value; model.refreshHover() }
            .onChange(of: draft.reduceMotion) { _, value in model.settings.reduceMotion = value }
            .onChange(of: draft.inactiveStackOpacity) { _, value in
                model.settings.inactiveStackOpacity = value
                if !model.isLiveTest { model.settings.save() }
            }
            .onChange(of: draft.blockAds) { _, value in
                model.settings.blockAds = value
                if !model.isLiveTest { model.settings.save() }
            }
    }
    var general: some View {
        VStack(spacing:15) {
            card {
                Label("A quiet side screen",systemImage:"rectangle.stack").font(.system(size:16,weight:.medium))
                Text("Summon a small command window. Leave music and timers on compact task cards. Click a card for more, or hide it while its task continues.").font(.system(size:12)).foregroundStyle(.secondary)
                Picker("Open Orvlet",selection:$draft.shortcut) {
                    ForEach(SummonShortcut.allCases,id:\.self) { Text($0.title).tag($0) }
                }
                Text(model.shortcutStatus).font(.system(size:11)).foregroundStyle(.secondary)
                Text("Esc closes the command window and returns to your previous app. It does not stop your tasks.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            card {
                Picker("Compact layout",selection:$draft.compactLayout) {
                    ForEach(CompactLayout.allCases,id:\.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("Two tasks stay visible. Music and timers take priority; all tasks and controls are available from the stack button.").font(.system(size:11)).foregroundStyle(.secondary)
                HStack {
                    Text("Inactive opacity").font(.system(size:12))
                    Slider(value:$draft.inactiveStackOpacity,in:0.1...1,step:0.05).accessibilityLabel("Inactive stack opacity")
                    Text("\(Int((draft.inactiveStackOpacity * 100).rounded()))%").font(.system(size:11)).monospacedDigit().frame(width:36,alignment:.trailing)
                }
                Text("The stack fades after 3 seconds without attention. Hover, focus, or expand to restore it. 100% keeps it fully visible.").font(.system(size:11)).foregroundStyle(.secondary)
                Toggle("Block ads in built-in browser",isOn:$draft.blockAds)
                Text("Blocks advertising requests and hides ad placements. YouTube ads are skipped when a skip control is available. Reload a page after changing this setting; some video ads may remain.").font(.system(size:11)).foregroundStyle(.secondary)
                if let error = model.adBlockingError { Text(error).font(.system(size:11)).foregroundStyle(.secondary) }
                Toggle("Restore last session",isOn:$draft.restoreLastSession)
                Toggle("Resume playback on launch",isOn:$draft.resumePlaybackOnLaunch)
                Text("Timers can run without a model. Connect a model for natural-language requests and generated interfaces.").font(.system(size:11)).foregroundStyle(.secondary)
            }
        }
    }
    var intelligence: some View {
        VStack(spacing: 15) {
            card {
                HStack {
                    Label("Main model", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Spacer(); badge("Required", color: draft.theme.color)
                }
                Text("Understands your requests and builds controls from webpages.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                entry("Base URL", placeholder: "https://example.com/v1", text: $draft.main.baseURL)
                entry("Model", placeholder: "Model ID from your provider", text: $draft.main.model)
                keyEntry("API Key", value: $mainKey)
                Toggle(isOn: $draft.main.vision) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Supports images").font(.system(size: 12))
                        Text("For visual content that page structure cannot describe.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small)
                HStack {
                    testButton("main", title: "Test connection")
                    Text(mainResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                DisclosureGroup("Supported services") {
                    Text("OpenAI-compatible Chat Completions with tool calling. Enter a Base URL or the full /chat/completions URL.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 5)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Keys stay in macOS Keychain. Page context is sent to your configured model when needed.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5)
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
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(draft.theme.color.opacity(0.3), lineWidth: 0.5))
                    Spacer()
                }.padding(.vertical, 10)
                HStack(spacing: 18) {
                    ForEach(ThemeTone.allCases, id: \.self) { tone in
                        Button { draft.theme = tone } label: {
                            VStack(spacing: 8) {
                                Circle().fill(tone.color.gradient).frame(width: 31, height: 31)
                                    .overlay(Circle().strokeBorder(.primary.opacity(draft.theme == tone ? 0.8 : 0), lineWidth: 2).padding(-4))
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
                Toggle("Reduce motion", isOn: $draft.reduceMotion).toggleStyle(.switch).controlSize(.small)
                Toggle("Adapt controls automatically", isOn: $draft.autoAdapt).toggleStyle(.switch).controlSize(.small)
            }
        }
    }
    var connections: some View {
        VStack(spacing: 15) {
            card {
                HStack { Label("Browser & agents", systemImage: "link").font(.system(size: 14, weight: .medium)); Spacer() }
                Toggle("Allow local connections", isOn: $draft.allowAgents).toggleStyle(.switch).controlSize(.small)
                Text("Connect your browser session, or let Codex and DSH control Orvlet through MCP.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.settings.allowAgents {
                    Text(model.bridgeStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.bridge.token, forType: .string); notice = "Pairing code copied" }
                    Toggle("Use connected browser", isOn: $model.externalBrowser).disabled(!model.browserConnected).toggleStyle(.switch).controlSize(.small)
                }
            }
            card {
                Picker("Compact layout",selection:$draft.compactLayout) {
                    ForEach(CompactLayout.allCases,id:\.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("Two tasks stay visible. Music and timers take priority; all tasks and controls are available from the stack button.").font(.system(size:11)).foregroundStyle(.secondary)
                Toggle("Restore last session", isOn:$draft.restoreLastSession).toggleStyle(.switch).controlSize(.small)
                Toggle("Resume playback on launch", isOn:$draft.resumePlaybackOnLaunch).toggleStyle(.switch).controlSize(.small).disabled(!draft.restoreLastSession)
                Label("Local memory", systemImage: "clock.arrow.circlepath").font(.system(size: 14, weight: .medium))
                LabeledContent("Saved interfaces", value: "\(model.adaptive.cache.entries.count)").font(.system(size: 12))
                LabeledContent("Recent visits", value: "\(model.history.count)").font(.system(size: 12))
                HStack {
                    Button("Clear interface cache", role: .destructive) { model.adaptive.cache.clear(); notice = "Interface cache cleared" }
                    Button("Clear web cache") { Task { await model.browser.clearResourceCache(); notice = "Web cache cleared" } }
                    Button("Clear history", role: .destructive) { model.clearRecentSessions(); notice = "History cleared" }
                }.font(.system(size: 11))
            }
        }
    }
    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 19)).overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
    func badge(_ title: String, color: Color) -> some View { Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4).background(color.opacity(0.12), in: Capsule()) }
    func entry(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(title)
        }
    }
    func keyEntry(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            SecureField("Paste key · stored locally", text: value).textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(title)
        }
    }
    func testButton(_ which: String, title: String) -> some View {
        Button { test(which) } label: {
            HStack(spacing: 6) { if testing == which { ProgressView().controlSize(.mini) }; Text(testing == which ? "Connecting…" : title) }
        }.disabled(!testing.isEmpty || !(which == "main" ? draft.main.isConfigured : draft.fast.isConfigured)).controlSize(.small)
    }
    func save() {
        do {
            try SecretStore.save(mainKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "main")
            // Preserve the old optional provider key; local visibility no longer needs it.
            let previous = model.settings.allowAgents
            draft.useFast = false; draft.fastProtocol = "jev"
            model.settings = draft; draft.save(); model.onShortcutChanged?()
            if draft.allowAgents && !previous { model.bridge.start() }
            if !draft.allowAgents && previous { model.bridge.stop() }
            notice = "Saved"
            if model.surface.markup == nil { model.adaptive.changed(force:true) }
        } catch { notice = error.localizedDescription }
    }
    func test(_ which: String) {
        testing = which
        Task {
            defer { testing = "" }
            do {
                if which == "main" {
                    _ = try await APIClient.complete(endpoint: draft.main, key: mainKey, messages: [["role": "user", "content": "Reply with OK."]], tools: [])
                    mainResult = "Connected"
                } else {
                    let result = try await JevClient.judge(endpoint: draft.fast, key: fastKey, state: "The user is listening to music in the background.", questions: ["audio": "Is the user listening to music?"])
                    fastResult = result["audio"] == nil ? "Unexpected response format" : "Connected"
                }
            } catch { if which == "main" { mainResult = error.localizedDescription } else { fastResult = error.localizedDescription } }
        }
    }
}
