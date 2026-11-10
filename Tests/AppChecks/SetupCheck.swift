#if DEBUG
    import AppKit
    import SwiftUI
    import Carbon

    @MainActor
    enum SetupCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            do {
                let all = try CalendarNativeTransport.all(CalendarNativeTransport.code("wres"))
                try check(
                    all.forKeyword(AEKeyword(keyAEKeyData))?.descriptorType == DescType(typeAbsoluteOrdinal),
                    "Native Calendar collections use an absolute ordinal, not an incompatible enum")
                let arguments = [
                    "create", "工作", "A quote \" and newline\n$(never execute)", "2030-06-18T10:00:00",
                    "2030-06-18T11:00:00", "Room A", "Notes\nwith text", "https://example.com/event", "false",
                ]
                let event = try CalendarNativeTransport.makeEventRequest(arguments)
                let properties = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))!
                try check(
                    event.eventID == OSType(kAECreateElement)
                        && event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.data
                            == Data("com.apple.iCal".utf8),
                    "Calendar creation is a fixed native event addressed only to Calendar")
                try check(
                    properties.forKeyword(CalendarNativeTransport.code("wr11"))?.stringValue == arguments[2]
                        && properties.forKeyword(CalendarNativeTransport.code("wr12"))?.stringValue == arguments[6],
                    "Event titles and notes remain literal descriptor data, never executable script text")
                try check(
                    properties.forKeyword(CalendarNativeTransport.code("wr1s"))?.dateValue
                        == CalendarNativeTransport.date(arguments[3])
                        && properties.forKeyword(CalendarNativeTransport.code("wrad"))?.booleanValue == false,
                    "Native event dates and all-day state match the verified request")
                var invalid = arguments
                invalid[4] = arguments[3]
                var rejected = false
                do { _ = try CalendarNativeTransport.makeEventRequest(invalid) } catch { rejected = true }
                try check(rejected, "Invalid event ranges are rejected before any native write")
                let query = try CalendarNativeTransport.matchingEvents(
                    in: CalendarNativeTransport.calendar("工作"), start: CalendarNativeTransport.date(arguments[3]))
                try check(
                    query.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formTest)
                        && query.forKeyword(AEKeyword(keyAEKeyData))?.descriptorType == DescType(typeCompDescriptor),
                    "Duplicate lookup uses an exact native date comparison")
                rejected = false
                do { _ = try CalendarNativeTransport.run(["delete", "anything"]) } catch { rejected = true }
                try check(rejected, "Calendar transport cannot execute arbitrary commands or delete events")
                let calendar = CalendarService()
                var scripts: [[String]] = []
                var prompts: [Bool] = []
                calendar.runnerOverride = { args in
                    scripts.append(args)
                    return "[{\"name\":\"Private calendar\",\"writable\":true}]"
                }
                calendar.permissionOverride = { prompt in
                    prompts.append(prompt)
                    return OSStatus(errAEEventWouldRequireUserConsent)
                }
                let unknown = await calendar.checkAccess(requestPermission: false)
                try check(
                    unknown == .permissionNeeded && prompts == [false] && scripts.isEmpty,
                    "A quiet preflight never requests consent or reads calendars without access")
                calendar.permissionOverride = { prompt in
                    prompts.append(prompt)
                    return OSStatus(errAEEventNotPermitted)
                }
                let denied = await calendar.checkAccess(requestPermission: true)
                try check(
                    denied == .blocked && scripts.isEmpty, "Denied permission remains blocked, never marked ready")
                calendar.permissionOverride = { _ in noErr }
                let allowed = await calendar.checkAccess(requestPermission: true)
                try check(
                    allowed == .ready && scripts == [["list"]],
                    "Calendar readiness checks writable calendars through the production read-only operation")
                calendar.runnerOverride = { _ in "[{\"name\":\"Read only\",\"writable\":false}]" }
                let readOnly = await calendar.checkAccess(requestPermission: false)
                try check(!readOnly.ready, "Authorization without a writable calendar is not completion")
                calendar.runnerOverride = { _ in "not JSON" }
                let malformed = await calendar.checkAccess(requestPermission: false)
                try check(!malformed.ready, "Invalid calendar evidence cannot mark permission setup ready")
                calendar.runnerOverride = { _ in throw AppError.message("Allow access in Automation") }
                let revoked = await calendar.checkAccess(requestPermission: false)
                try check(revoked == .blocked, "Denied access on the actual script path overrides an allowed preflight")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "orvlet-setup-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                try AppModel.verifyLocalStorage(at: directory)
                try check(
                    try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                    "Storage verification reads back and removes its own temporary marker")
                let file = directory.appendingPathComponent("not-a-directory")
                try Data().write(to: file)
                var writeBlocked = false
                do { try AppModel.verifyLocalStorage(at: file) } catch { writeBlocked = true }
                try check(writeBlocked, "An unusable storage location is reported before task persistence")

                let storeName = "orvlet-setup-check-" + UUID().uuidString
                let store = UserDefaults(suiteName: storeName)!
                defer { store.removePersistentDomain(forName: storeName) }
                let isolated = AppModel(defaults: store)
                isolated.isLiveTest = true
                isolated.persistHistory = false
                isolated.settings.useFast = true
                isolated.settings.allowAgents = false
                isolated.readinessStorageOverride = {}
                isolated.readinessConnectionsOverride = {
                    isolated.mainServiceState = "ready"
                    isolated.fastServiceState = "ready"
                }
                var shown = 0
                var permissionCalls: [Bool] = []
                isolated.onSetup = { shown += 1 }
                isolated.calendarService.permissionOverride = { prompt in
                    permissionCalls.append(prompt)
                    return noErr
                }
                isolated.calendarService.runnerOverride = { args in
                    guard args == ["list"] else { throw AppError.message("Setup attempted a calendar write") }
                    return "[{\"writable\":true}]"
                }
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(
                    shown > 0 && permissionCalls == [false] && !isolated.setupReady && !isolated.setupReviewed,
                    "First launch checks existing access without consent prompts and still waits for the user's selection"
                )
                permissionCalls = []
                isolated.configureAccess(calendar: true, connections: false)
                await isolated.readinessTask?.value
                try check(
                    permissionCalls == [true] && isolated.setupReady && store.bool(forKey: "setup.verified.v1"),
                    "User selection requests access and marks completion only after all selected checks pass")
                try check(
                    isolated.setupReady && isolated.fastServiceState == "ready",
                    "Both configured models are required for setup completion")
                shown = 0
                permissionCalls = []
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(
                    permissionCalls == [false] && shown == 0 && isolated.setupReady,
                    "Subsequent healthy launches verify access silently without prompting again")
                isolated.calendarService.permissionOverride = { _ in OSStatus(errAEEventNotPermitted) }
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(
                    !isolated.setupReady && !store.bool(forKey: "setup.verified.v1") && shown > 0,
                    "Revoked access invalidates completion and opens setup before a user task")
                permissionCalls = []
                isolated.calendarService.permissionOverride = { prompt in
                    permissionCalls.append(prompt)
                    return noErr
                }
                isolated.configureAccess(calendar: false, connections: false)
                await isolated.readinessTask?.value
                try check(
                    permissionCalls.isEmpty && isolated.calendarReadiness == .off && isolated.setupReady,
                    "An opted-out capability neither requests permission nor blocks unrelated features")
                isolated.readinessStorageOverride = { throw AppError.message("Full disk") }
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(
                    !isolated.setupReady && isolated.storageReadiness != .ready,
                    "Storage failure prevents a false ready result")
                isolated.readinessStorageOverride = {}
                isolated.readinessConnectionsOverride = {
                    isolated.mainServiceState = "ready"
                    isolated.fastServiceState = "unconfigured"
                }
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(!isolated.setupReady, "Missing required Jev configuration blocks setup completion")
                isolated.readinessConnectionsOverride = {
                    isolated.mainServiceState = "ready"
                    isolated.fastServiceState = "ready"
                }
                isolated.shortcutStatus = "Shortcut in use"
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(!isolated.setupReady, "A shortcut conflict is caught during setup")
                isolated.shortcutStatus = "Ready"
                isolated.bridgeStatus = "127.0.0.1:19243"
                isolated.configureAccess(calendar: false, connections: true)
                await isolated.readinessTask?.value
                try check(
                    isolated.setupReady && isolated.settings.allowAgents && isolated.connectionReadiness == .ready,
                    "All selected local integrations must be reachable before setup is ready")
                for path in ["/browser/poll", "/browser/state", "/browser/result"] {
                    var rejected = false
                    do { _ = try await isolated.bridge.route(path, [:]) } catch { rejected = true }
                    try check(
                        rejected && !isolated.browserConnected && !isolated.externalBrowser,
                        "Hidden browser integration rejects \(path) without activating external control")
                }
                let bridgeState = try await isolated.bridge.route("/rpc", ["tool": "state"])
                try check(
                    bridgeState["browserConnected"] as? Bool == false,
                    "Agent state access remains available while browser pairing is hidden")
                var passes = 0
                isolated.readinessConnectionsOverride = {
                    passes += 1
                    try? await Task.sleep(for: .milliseconds(30))
                    isolated.mainServiceState = passes == 1 ? "unavailable" : "ready"
                }
                isolated.checkStartupReadiness()
                isolated.checkStartupReadiness()
                while isolated.setupChecking { try await Task.sleep(for: .milliseconds(20)) }
                try check(
                    passes == 2 && isolated.setupReady,
                    "Changes during a check queue one fresh check instead of accepting stale settings")
                shown = 0
                isolated.setupDismissed = true
                isolated.readinessConnectionsOverride = { isolated.mainServiceState = "unavailable" }
                isolated.checkStartupReadiness()
                await isolated.readinessTask?.value
                try check(shown == 0, "Dismissing setup does not make a finishing check reopen it")

                isolated.settings.useFast = true
                isolated.settings.allowAgents = true
                isolated.settings.appearance = .light
                isolated.settings.compactTaskLimit = AppSettings().compactTaskLimit
                isolated.preferences.set(true, forKey: "setup.reviewed.v1")
                isolated.preferences.set(true, forKey: "setup.calendar.enabled")
                isolated.mainServiceState = "ready"
                isolated.fastServiceState = "ready"
                isolated.storageReadiness = .ready
                isolated.calendarReadiness = .blocked
                isolated.connectionReadiness = .ready
                delegate.showSetup(for: isolated)
                try await Task.sleep(for: .milliseconds(500))
                guard let window = delegate.settingsWindow else { throw AppError.message("Access page missing") }
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-setup-attention.png")
                try check(
                    window.isVisible && window.canBecomeKey,
                    "Access opens in a visible Settings window that accepts keyboard focus")
                isolated.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(300))
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-setup-dark.png")
                isolated.settings.appearance = .light
                isolated.calendarReadiness = .ready
                try await Task.sleep(for: .milliseconds(300))
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-setup-ready.png")
                try check(isolated.setupReady, "The ready layout is shown only with verified selected access")
                let originalWindow = window
                delegate.openSettings(tab: 0, for: isolated)
                try await Task.sleep(for: .milliseconds(250))
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-settings-general.png")
                delegate.showSetup(for: isolated)
                try await Task.sleep(for: .milliseconds(250))
                try check(
                    delegate.settingsWindow === originalWindow && window.isVisible && window.canBecomeKey,
                    "Reopening access reuses the visible keyboard-capable Settings window")
                for (tab, name) in [(1, "appearance"), (2, "models"), (3, "access"), (4, "data")] {
                    delegate.openSettings(tab: tab, for: isolated)
                    try await Task.sleep(for: .milliseconds(300))
                    try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-settings-" + name + ".png")
                }
                window.close()
                try check(
                    isolated.setupDismissed, "Closing Settings dismisses automatic access attention for its owner")
                delegate.showSetup(for: isolated)
                try await Task.sleep(for: .milliseconds(250))
                try check(
                    window.isVisible && !isolated.setupDismissed, "Access can be opened again after closing Settings")
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: .prettyPrinted)
                    .write(to: URL(fileURLWithPath: "/tmp/orvlet-setup-checks.json"))
                if CommandLine.arguments.contains("--hold-settings-check") {
                    delegate.openSettings(tab: 1, for: isolated)
                    try await Task.sleep(for: .seconds(180))
                }
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-setup-checks.json"))
                exit(1)
            }
        }
    }
#endif
