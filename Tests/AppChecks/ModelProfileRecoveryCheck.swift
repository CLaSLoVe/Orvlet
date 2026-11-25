#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum ModelProfileRecoveryCheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ label: String) throws {
            try StateMachineCheck.require(value, label, &checks)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orvlet-profile-recovery-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let prefs = library.appendingPathComponent("Preferences/app.orvlet.desktop.plist")
        let secrets = library.appendingPathComponent("Application Support/Orvlet/Private/credentials-v1.json")
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: secrets.deletingLastPathComponent(), withIntermediateDirectories: true)
        var previous = AppSettings()
        previous.main = Endpoint(baseURL: "https://previous.example/v1", model: "previous-model")
        previous.ensureProfiles()
        let originalID = previous.activeProfileID
        let originalAccount = previous.mainConnection.keyAccount
        previous.addProfile()
        previous.main = Endpoint(baseURL: "https://second.example/v1", model: "second-model")
        previous.storeActiveProfile()
        let secondAccount = previous.mainConnection.keyAccount
        _ = previous.selectProfile(originalID)
        let originalPreferences = try PropertyListSerialization.data(fromPropertyList:
            ["modelSettings": JSONEncoder().encode(previous)], format: .binary, options: 0)
        let originalSecrets = try JSONEncoder().encode([originalAccount: "fixture-old", secondAccount: "fixture-second", previous.fastKeyAccount: "fixture-fast"])
        try originalPreferences.write(to: prefs)
        try originalSecrets.write(to: secrets)
        let snapshot = try ModelProfileRecovery.read(library: library)
        let store = LocalCredentials(directory: root.appendingPathComponent("destination/Private"))
        let result = try ModelProfileRecovery.restore(snapshot, into: AppSettings(), store: store)
        try require(result.settings.main == previous.main && result.profiles == 2
            && (try store.load(result.settings.mainConnection.keyAccount)) == "fixture-old",
            "Recovery restores previous profiles and their saved keys into the new data location")
        try require(try store.load(result.settings.fastKeyAccount) == "fixture-fast",
            "Recovery restores the shared Jev key as well as main-model keys")
        try require(try Data(contentsOf: prefs) == originalPreferences && Data(contentsOf: secrets) == originalSecrets,
            "Recovering model profiles leaves the original preferences and credentials unchanged")
        try store.save("fixture-newer", account: result.settings.mainConnection.keyAccount)
        let repeated = try ModelProfileRecovery.restore(snapshot, into: result.settings, store: store)
        try require(repeated.settings.profiles.count == result.settings.profiles.count
            && repeated.settings.fastKeyAccount == result.settings.fastKeyAccount
            && (try store.load(repeated.settings.mainConnection.keyAccount)) == "fixture-newer",
            "Repeated recovery adds no duplicates and never overwrites newer saved credentials")

        var changed = previous
        changed.main = Endpoint(baseURL: "https://different.example/v1", model: "new-provider")
        changed.storeActiveProfile()
        let changedStore = LocalCredentials(directory: root.appendingPathComponent("changed/Private"))
        try changedStore.save("fixture-current", account: changed.mainConnection.keyAccount)
        let conflict = try ModelProfileRecovery.restore(snapshot, into: changed, store: changedStore)
        let restoredOld = conflict.settings.profiles.first { $0.endpoint == previous.main }!
        try require(conflict.settings.main == changed.main
            && restoredOld.keyAccount != changed.mainConnection.keyAccount
            && (try changedStore.load(restoredOld.keyAccount)) == "fixture-old"
            && (try changedStore.load(changed.mainConnection.keyAccount)) == "fixture-current",
            "A conflicting profile ID cannot attach an old key to a different provider")
        try Data("invalid fixture".utf8).write(to: secrets)
        var rejected = false
        do { _ = try ModelProfileRecovery.read(library: library) } catch { rejected = true }
        try require(rejected && (try store.load(result.settings.mainConnection.keyAccount)) == "fixture-newer",
            "Unreadable legacy data leaves the current credential store intact")
        try fm.removeItem(at: secrets)
        let outside = root.appendingPathComponent("outside.json")
        try originalSecrets.write(to: outside)
        try fm.createSymbolicLink(at: secrets, withDestinationURL: outside)
        rejected = false
        do { _ = try ModelProfileRecovery.read(library: library) } catch { rejected = true }
        try require(rejected, "Profile recovery rejects redirected credential files")

        let suite = "orvlet-profile-recovery-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.settings = result.settings
        model.settings.autoAdapt = false
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = NSPanel(contentRect: NSRect(x: -16000, y: -16000, width: 520, height: 710),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.orderOut(nil); model.browser.dispose(); model.taskRuntime.stopAll() }
        for appearance in [AppAppearance.light, .dark] {
            model.settings.appearance = appearance
            panel.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: 2))
            panel.orderBack(nil)
            panel.contentView?.layoutSubtreeIfNeeded()
            try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-profile-recovery-\(appearance.rawValue).png")
            // Send modifier changes only to this hidden test app, never to the desktop.
            for flags in [NSEvent.ModifierFlags.option, []] {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
                NSApp.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                panel.contentView?.layoutSubtreeIfNeeded()
                let state = flags.isEmpty ? "released" : "option"
                try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-profile-recovery-\(appearance.rawValue)-\(state).png")
            }
        }
        panel.orderOut(nil)
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !panel.isVisible,
            "Recovery settings render offscreen without opening a picker or changing desktop focus")
        return checks
    }
}
#endif
