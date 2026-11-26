import SwiftUI

enum ThemeTone: String, Codable, CaseIterable {
    case iris, mint, peach, sky, rose, stone
    var title: String {
        switch self {
        case .iris: "Iris"
        case .mint: "Mint"
        case .peach: "Peach"
        case .sky: "Sky"
        case .rose: "Rose"
        case .stone: "Stone"
        }
    }
    var color: Color {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0xa49bdf
        return Color(
            red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255)
    }
}
enum AppAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
enum CompactLayout: String, Codable, CaseIterable {
    case vertical, horizontal
    var title: String { self == .vertical ? "Vertical" : "Horizontal" }
}
enum TaskStartPolicy: String, Codable, CaseIterable {
    case taskFirst, interfaceFirst
    var title: String { self == .taskFirst ? "Task first" : "Interface first" }
}
struct AppSettings: Codable {
    static let defaultInterfaceLanguage = "English"
    var interfaceLanguage = defaultInterfaceLanguage
    var preferredInterfaceLanguage: String {
        let name = interfaceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.defaultInterfaceLanguage : name
    }
    var interfaceLanguageInstruction: String {
        "Generated interface language (user preference): " + JSONText.encode(["language": preferredInterfaceLanguage])
    }
    var taskStartPolicy = TaskStartPolicy.taskFirst
    var compactLayout = CompactLayout.vertical
    var compactTaskLimit = 3
    static let compactTaskLimits = 1...6
    var inactiveStackOpacity = 0.55
    var blockAds = true
    var browserEngine = BrowserEngine.builtIn
    var shortcut = SummonShortcut.optionSpace
    var main = Endpoint()
    var profiles: [ModelProfile] = []
    var activeProfileID = "legacy"
    var preferredModelProfiles: [String: String] = [:]
    var fastCredentialID: String? = nil
    var fast = Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
    var fastProtocol = "jev"
    var fastKeyReference: String? = nil
    var decisionConfigurations: [String: DecisionConfiguration] = [:]
    var useFast = true
    var autoAdapt = true
    var allowAgents = false
    var theme = ThemeTone.iris
    var appearance = AppAppearance.dark
    var alarmSound = ReminderSound.slowRise
    var messageSound = ReminderSound.bamboo

    func sound(for persistence: ReminderPersistence) -> ReminderSound {
        persistence == .persistent ? alarmSound : messageSound
    }
    var reduceMotion = false
    var expandOnHover = false
    var restoreLastSession = true
    var resumePlaybackOnLaunch = false
    init() {}
    enum CodingKeys: String, CodingKey {
        case fastKeyReference, decisionConfigurations, preferredModelProfiles
        case interfaceLanguage, profiles, activeProfileID, fastCredentialID, taskStartPolicy, compactLayout, compactTaskLimit,
            inactiveStackOpacity, blockAds, browserEngine, shortcut, main, fast, fastProtocol, useFast, autoAdapt, allowAgents, theme,
            appearance, alarmSound, messageSound, reduceMotion, expandOnHover, restoreLastSession, resumePlaybackOnLaunch
    }
    private enum LegacySoundKey: String, CodingKey { case reminderSound }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interfaceLanguage = try c.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? Self.defaultInterfaceLanguage
        taskStartPolicy = try c.decodeIfPresent(TaskStartPolicy.self, forKey: .taskStartPolicy) ?? .taskFirst
        compactLayout = try c.decodeIfPresent(CompactLayout.self, forKey: .compactLayout) ?? .vertical
        compactTaskLimit = min(6, max(1, try c.decodeIfPresent(Int.self, forKey: .compactTaskLimit) ?? 3))
        inactiveStackOpacity = min(
            1, max(0.1, try c.decodeIfPresent(Double.self, forKey: .inactiveStackOpacity) ?? 0.55))
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? true
        browserEngine = try c.decodeIfPresent(BrowserEngine.self, forKey: .browserEngine) ?? .builtIn
        shortcut = try c.decodeIfPresent(SummonShortcut.self, forKey: .shortcut) ?? .optionSpace
        main = try c.decodeIfPresent(Endpoint.self, forKey: .main) ?? Endpoint()
        profiles = try c.decodeIfPresent([ModelProfile].self, forKey: .profiles) ?? []
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? "legacy"
        preferredModelProfiles = try c.decodeIfPresent([String: String].self, forKey: .preferredModelProfiles) ?? [:]
        fastCredentialID = try c.decodeIfPresent(String.self, forKey: .fastCredentialID)
        fast =
            try c.decodeIfPresent(Endpoint.self, forKey: .fast)
            ?? Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
        fastProtocol = try c.decodeIfPresent(String.self, forKey: .fastProtocol) ?? "jev"
        fastKeyReference = try c.decodeIfPresent(String.self, forKey: .fastKeyReference)
        decisionConfigurations = try c.decodeIfPresent([String: DecisionConfiguration].self, forKey: .decisionConfigurations) ?? [:]
        useFast = true  // Migrate optional Jev configurations to the required dual-model setup.
        autoAdapt = try c.decodeIfPresent(Bool.self, forKey: .autoAdapt) ?? true
        allowAgents = try c.decodeIfPresent(Bool.self, forKey: .allowAgents) ?? false
        theme = try c.decodeIfPresent(ThemeTone.self, forKey: .theme) ?? .iris
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
        let old = try decoder.container(keyedBy: LegacySoundKey.self)
        let sharedSound = try old.decodeIfPresent(String.self, forKey: .reminderSound).flatMap(ReminderSound.init(rawValue:))
        alarmSound = try (c.decodeIfPresent(String.self, forKey: .alarmSound).flatMap(ReminderSound.init(rawValue:)) ?? sharedSound ?? .slowRise).alarmPreference
        messageSound = try (c.decodeIfPresent(String.self, forKey: .messageSound).flatMap(ReminderSound.init(rawValue:)) ?? sharedSound ?? .bamboo).messagePreference
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        expandOnHover = try c.decodeIfPresent(Bool.self, forKey: .expandOnHover) ?? false
        restoreLastSession = try c.decodeIfPresent(Bool.self, forKey: .restoreLastSession) ?? true
        resumePlaybackOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumePlaybackOnLaunch) ?? false
        ensureProfiles()
    }
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "modelSettings"),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "modelSettings") }
    }
}
extension AppSettings {
    // Each settings page owns its fields; an older draft must never undo an
    // access choice or save unfinished model credentials from another page.
    mutating func applyPreferences(from draft: AppSettings) {
        interfaceLanguage = draft.preferredInterfaceLanguage
        shortcut = draft.shortcut
        compactLayout = draft.compactLayout
        compactTaskLimit = draft.compactTaskLimit
        theme = draft.theme
        appearance = draft.appearance
        alarmSound = draft.alarmSound
        messageSound = draft.messageSound
        reduceMotion = draft.reduceMotion
        expandOnHover = draft.expandOnHover
        inactiveStackOpacity = draft.inactiveStackOpacity
        taskStartPolicy = draft.taskStartPolicy
        blockAds = draft.blockAds
        browserEngine = draft.browserEngine
        autoAdapt = draft.autoAdapt
        restoreLastSession = draft.restoreLastSession
        resumePlaybackOnLaunch = draft.resumePlaybackOnLaunch
    }
    mutating func applyModels(from draft: AppSettings) {
        profiles = draft.profiles
        activeProfileID = draft.activeProfileID
        preferredModelProfiles = draft.preferredModelProfiles
        main = draft.main
        fast = draft.fast
        fastCredentialID = draft.fastCredentialID
        fastProtocol = draft.fastProtocol
        fastKeyReference = draft.fastKeyReference
        decisionConfigurations = draft.decisionConfigurations
        useFast = true
    }
}
