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
    var taskStartPolicy = TaskStartPolicy.taskFirst
    var compactLayout = CompactLayout.vertical
    var compactTaskLimit = 3
    static let compactTaskLimits = 1...6
    var inactiveStackOpacity = 0.55
    var blockAds = true
    var shortcut = SummonShortcut.optionSpace
    var main = Endpoint()
    var profiles: [ModelProfile] = []
    var activeProfileID = "legacy"
    var fastCredentialID: String? = nil
    var fast = Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
    var fastProtocol = "jev"
    var useFast = true
    var autoAdapt = true
    var allowAgents = false
    var theme = ThemeTone.iris
    var appearance = AppAppearance.dark
    var reduceMotion = false
    var expandOnHover = false
    var restoreLastSession = true
    var resumePlaybackOnLaunch = false
    init() {}
    enum CodingKeys: String, CodingKey {
        case profiles, activeProfileID, fastCredentialID, taskStartPolicy, compactLayout, compactTaskLimit,
            inactiveStackOpacity, blockAds, shortcut, main, fast, fastProtocol, useFast, autoAdapt, allowAgents, theme,
            appearance, reduceMotion, expandOnHover, restoreLastSession, resumePlaybackOnLaunch
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskStartPolicy = try c.decodeIfPresent(TaskStartPolicy.self, forKey: .taskStartPolicy) ?? .taskFirst
        compactLayout = try c.decodeIfPresent(CompactLayout.self, forKey: .compactLayout) ?? .vertical
        compactTaskLimit = min(6, max(1, try c.decodeIfPresent(Int.self, forKey: .compactTaskLimit) ?? 3))
        inactiveStackOpacity = min(
            1, max(0.1, try c.decodeIfPresent(Double.self, forKey: .inactiveStackOpacity) ?? 0.55))
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? true
        shortcut = try c.decodeIfPresent(SummonShortcut.self, forKey: .shortcut) ?? .optionSpace
        main = try c.decodeIfPresent(Endpoint.self, forKey: .main) ?? Endpoint()
        profiles = try c.decodeIfPresent([ModelProfile].self, forKey: .profiles) ?? []
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? "legacy"
        fastCredentialID = try c.decodeIfPresent(String.self, forKey: .fastCredentialID)
        fast =
            try c.decodeIfPresent(Endpoint.self, forKey: .fast)
            ?? Endpoint(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest")
        fastProtocol = try c.decodeIfPresent(String.self, forKey: .fastProtocol) ?? "jev"
        useFast = true  // Migrate optional Jev configurations to the required dual-model setup.
        autoAdapt = try c.decodeIfPresent(Bool.self, forKey: .autoAdapt) ?? true
        allowAgents = try c.decodeIfPresent(Bool.self, forKey: .allowAgents) ?? false
        theme = try c.decodeIfPresent(ThemeTone.self, forKey: .theme) ?? .iris
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
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
        shortcut = draft.shortcut
        compactLayout = draft.compactLayout
        compactTaskLimit = draft.compactTaskLimit
        theme = draft.theme
        appearance = draft.appearance
        reduceMotion = draft.reduceMotion
        expandOnHover = draft.expandOnHover
        inactiveStackOpacity = draft.inactiveStackOpacity
        taskStartPolicy = draft.taskStartPolicy
        blockAds = draft.blockAds
        autoAdapt = draft.autoAdapt
        restoreLastSession = draft.restoreLastSession
        resumePlaybackOnLaunch = draft.resumePlaybackOnLaunch
    }
    mutating func applyModels(from draft: AppSettings) {
        profiles = draft.profiles
        activeProfileID = draft.activeProfileID
        main = draft.main
        fast = draft.fast
        fastCredentialID = draft.fastCredentialID
        fastProtocol = draft.fastProtocol
        useFast = true
    }
}
