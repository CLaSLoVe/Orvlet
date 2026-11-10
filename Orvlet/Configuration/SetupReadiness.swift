import AppKit
import Carbon
import SwiftUI

enum AccessReadiness: Equatable {
    case unchecked, checking, ready, off, permissionNeeded, blocked
    case unavailable(String)
    var ready: Bool { self == .ready || self == .off }
    var label: String {
        switch self {
        case .unchecked: return "Not checked"
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .off: return "Off"
        case .permissionNeeded: return "Permission needed"
        case .blocked: return "Allow access in System Settings"
        case .unavailable(let reason): return reason
        }
    }
}

extension CalendarService {
    func checkAccess(requestPermission: Bool) async -> AccessReadiness {
        do {
            let permission: OSStatus
            #if DEBUG
                if let permissionOverride {
                    permission = await permissionOverride(requestPermission)
                } else {
                    permission = try await calendarPermission(requestPermission)
                }
            #else
                permission = try await calendarPermission(requestPermission)
            #endif
            try Task.checkCancellation()
            if permission == OSStatus(errAEEventWouldRequireUserConsent) { return .permissionNeeded }
            if permission == OSStatus(errAEEventNotPermitted) { return .blocked }
            guard permission == noErr else { return .unavailable("Open Calendar, then check again") }
            // Same signed transport and writable property used by event creation.
            // A granted TCC flag alone does not prove a writable calendar exists.
            let data = Data(try await run(["list"], allowPermissionPrompt: requestPermission).utf8)
            try Task.checkCancellation()
            guard let calendars = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .unavailable("Calendar access could not be verified")
            }
            return calendars.contains(where: { $0["writable"] as? Bool == true })
                ? .ready : .unavailable("Add a writable calendar in Calendar")
        } catch {
            #if DEBUG
                lastAccessIssue = error.localizedDescription
            #endif
            if error is CancellationError { return .unchecked }
            if error.localizedDescription.contains("Automation") || error.localizedDescription.contains("-1743") {
                return .blocked
            }
            return .unavailable("Calendar is not responding. Check again")
        }
    }
    private func calendarPermission(_ prompt: Bool) async throws -> OSStatus {
        // Apple requires a running target. Launch in the background without
        // reading events, then query on a worker thread (consent can block).
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iCal").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
                return OSStatus(procNotFound)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal")
            return AEDeterminePermissionToAutomateTarget(
                target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
        }.value
    }
}

extension AppModel {
    var calendarAccessEnabled: Bool { preferences.object(forKey: "setup.calendar.enabled") as? Bool ?? true }
    var setupReviewed: Bool { preferences.bool(forKey: "setup.reviewed.v1") }
    var setupReady: Bool {
        setupReviewed && mainServiceState == "ready" && fastServiceState == "ready"
            && (!calendarAccessEnabled || calendarReadiness == .ready)
            && storageReadiness == .ready && shortcutStatus == "Ready"
            && (!settings.allowAgents || connectionReadiness == .ready)
    }
    func configureAccess(calendar: Bool, connections: Bool) {
        preferences.set(calendar, forKey: "setup.calendar.enabled")
        preferences.set(true, forKey: "setup.reviewed.v1")
        settings.allowAgents = connections
        if !isLiveTest {
            settings.save()
            if connections { bridge.start() } else { bridge.stop() }
        }
        checkStartupReadiness(requestPermission: true, show: true)
    }
    func checkStartupReadiness(requestPermission: Bool = false, show: Bool = false) {
        #if DEBUG
            if isLiveTest && readinessConnectionsOverride == nil { return }
        #else
            guard !isLiveTest else { return }
        #endif
        if show { setupDismissed = false }
        if show || (!setupReviewed && !setupDismissed) { onSetup?() }
        guard !setupChecking else {
            readinessRecheckPending = true
            readinessPromptPending = readinessPromptPending || requestPermission
            return
        }
        setupChecking = true
        storageReadiness = .checking
        calendarReadiness = calendarAccessEnabled ? .unchecked : .off
        connectionReadiness = settings.allowAgents ? .checking : .off
        readinessTask = Task {
            defer { finishReadinessCheck() }
            do {
                #if DEBUG
                    if let readinessStorageOverride {
                        try readinessStorageOverride()
                    } else {
                        try Self.verifyLocalStorage()
                    }
                #else
                    try Self.verifyLocalStorage()
                #endif
                storageReadiness = .ready
            } catch { storageReadiness = .unavailable("Local saves need attention") }
            #if DEBUG
                if let readinessConnectionsOverride {
                    await readinessConnectionsOverride()
                } else {
                    checkModelConnections(notify: false)
                    await connectionCheckTask?.value
                }
            #else
                checkModelConnections(notify: false)
                await connectionCheckTask?.value
            #endif
            guard !Task.isCancelled else { return }
            if calendarAccessEnabled {
                calendarReadiness = .checking
                calendarReadiness = await calendarService.checkAccess(requestPermission: requestPermission)
            }
            guard !Task.isCancelled else { return }
            if settings.allowAgents {
                if !isLiveTest { bridge.start() }
                for _ in 0..<20 {
                    if bridgeStatus == "127.0.0.1:\(bridge.port)" { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                connectionReadiness =
                    bridgeStatus == "127.0.0.1:\(bridge.port)"
                    ? .ready : .unavailable("Local connections need attention")
            }
            preferences.set(setupReady, forKey: "setup.verified.v1")
            if !setupReady && !setupDismissed { onSetup?() }
        }
    }
    private func finishReadinessCheck() {
        setupChecking = false
        readinessTask = nil
        if readinessRecheckPending {
            let prompt = readinessPromptPending
            readinessRecheckPending = false
            readinessPromptPending = false
            checkStartupReadiness(requestPermission: prompt)
        }
    }
    func refreshSetupCalendar() {
        guard !setupChecking, setupReviewed, calendarAccessEnabled, calendarReadiness != .ready else { return }
        #if DEBUG
            if isLiveTest && calendarService.permissionOverride == nil { return }
        #endif
        setupChecking = true
        readinessTask = Task {
            defer { finishReadinessCheck() }
            calendarReadiness = .checking
            calendarReadiness = await calendarService.checkAccess(requestPermission: false)
            preferences.set(setupReady, forKey: "setup.verified.v1")
        }
    }
    static func verifyLocalStorage(
        at directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvlet")
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(".access-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let data = Data("Orvlet storage check".utf8)
        try data.write(to: marker, options: [.atomic])
        guard try Data(contentsOf: marker) == data else { throw AppError.message("Local storage read-back failed") }
    }
}

struct SetupReadinessView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let embedded: Bool
    @State private var calendar = true
    @State private var connections = false
    @State private var changed = false
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { model.settings.appearance.scheme ?? systemScheme }
    init(model: AppModel, embedded: Bool = false, close: @escaping () -> Void = {}) {
        self.model = model
        self.close = close
        self.embedded = embedded
        _calendar = State(initialValue: model.calendarAccessEnabled)
        _connections = State(initialValue: model.settings.allowAgents)
        _changed = State(initialValue: !model.setupReviewed)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 16 : 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(embedded ? "Access" : model.setupReady && !changed ? "You're ready" : "Set up Orvlet").font(
                    .system(size: embedded ? 18 : 23, weight: .medium, design: .rounded))
                Text(
                    model.setupReady && !changed
                        ? "Selected access is verified." : "Choose access once. We'll check it before you begin."
                ).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Recommended") {
                    calendar = true
                    connections = false
                    changed = true
                }
                Button("All available access") {
                    calendar = true
                    connections = true
                    changed = true
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(model.setupChecking)
            VStack(spacing: 0) {
                Toggle(isOn: $calendar) {
                    accessLabel("Calendar", detail: "Create events and verify they were saved.", symbol: "calendar")
                }
                .padding(.vertical, 12)
                Divider().opacity(0.4)
                Toggle(isOn: $connections) {
                    accessLabel("Agent connections", detail: "Connect external agents on this Mac.", symbol: "link")
                }
                .padding(.vertical, 12)
            }.toggleStyle(.switch).controlSize(.small).disabled(model.setupChecking)
                .onChange(of: calendar) { _, _ in changed = true }
                .onChange(of: connections) { _, _ in changed = true }
            VStack(spacing: 12) {
                status("Model & key", state: service(model.mainServiceState), action: "Models") {
                    model.onSetupModels?()
                }
                status("Jev & key", state: service(model.fastServiceState), action: "Models") {
                    model.onSetupModels?()
                }
                if calendar {
                    status(
                        "Calendar access",
                        state: calendar != model.calendarAccessEnabled ? .unchecked : model.calendarReadiness,
                        action: model.calendarReadiness == .blocked ? "Allow access" : "Open Calendar"
                    ) {
                        let url =
                            model.calendarReadiness == .blocked
                            ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
                        if let url { NSWorkspace.shared.open(url) }
                    }
                }
                status("Saved tasks", state: model.storageReadiness)
                status(
                    "Keyboard shortcut",
                    state: model.shortcutStatus == "Ready" ? .ready : .unavailable("Choose another shortcut"),
                    action: "Settings"
                ) { model.onSettings?() }
                if connections {
                    status(
                        "Local connections",
                        state: connections != model.settings.allowAgents ? .unchecked : model.connectionReadiness)
                }
            }.padding(14).background(
                .primary.opacity(scheme == .dark ? 0.045 : 0.025), in: RoundedRectangle(cornerRadius: 12))
            if !model.setupReady || changed {
                Text("macOS may ask you to confirm access.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !embedded && (!model.setupReady || changed) {
                    Button("Not now") {
                        model.setupDismissed = true
                        close()
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if model.setupChecking { ProgressView().controlSize(.small) }
                Button(
                    embedded
                        ? (changed || !model.setupReviewed ? "Apply & check" : "Check again")
                        : model.setupReady && !changed
                            ? "Done" : changed || !model.setupReviewed ? "Enable & check" : "Check again"
                ) {
                    if !embedded && model.setupReady && !changed {
                        close()
                    } else {
                        model.configureAccess(calendar: calendar, connections: connections)
                        changed = false
                    }
                }.buttonStyle(.borderedProminent).disabled(model.setupChecking).keyboardShortcut(.defaultAction)
            }
        }.padding(embedded ? 0 : 26).frame(maxWidth: .infinity, alignment: .leading).tint(model.accent)
            .background(CalmVisualStyle.windowFill(scheme))
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(model.settings.appearance.scheme)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if !changed { model.refreshSetupCalendar() }
            }
    }
    private func accessLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            CalmGlyph(symbol: symbol, accent: model.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func service(_ value: String) -> AccessReadiness {
        switch value {
        case "ready": return .ready
        case "checking": return .checking
        case "off": return .off
        case "unconfigured": return .unavailable("Connect in Models")
        case "unavailable": return .unavailable("Connection needs attention")
        default: return .unchecked
        }
    }
    private func status(
        _ title: String, state: AccessReadiness, action: String = "", perform: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 9) {
            Group {
                if state == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(
                        systemName: state == .ready
                            ? "checkmark.circle.fill" : state == .off ? "minus.circle" : "circle"
                    ).foregroundStyle(state == .ready ? model.accent : Color.secondary)
                }
            }.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium))
                if state != .ready {
                    Text(state.label).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if !state.ready && state != .checking && state != .unchecked && state != .permissionNeeded
                && !action.isEmpty
            {
                Button(action, action: perform).buttonStyle(.link).font(.system(size: 11))
            }
        }
    }
}
