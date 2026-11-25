#if DEBUG
import AppKit
import SwiftUI
import SQLite3

@MainActor
enum SystemBrowserCheck {
    static func start() async {
        var checks: [String] = []
        let suite = "orvlet-system-browser-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.reduceMotion = true
        model.settings.browserEngine = .systemBrowser
        let browser = model.browser
        browser.setUserPlaybackPaused(true, origin: "system_browser_check")
        var activations: Set<pid_t> = []
        var browserProcesses: Set<pid_t> = []
        let focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    activations.insert(app.processIdentifier)
                }
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        var other: BrowserController?
        var panel: NSPanel?
        func require(_ condition: Bool, _ label: String) throws {
            try StateMachineCheck.require(condition, label, &checks)
        }
        do {
            try require(NSApp.windows.allSatisfy { !$0.isVisible }, "System browser checks start without visible windows")
            let adguardSource = ProcessInfo.processInfo.environment["ORVLET_TEST_ADGUARD_DIR"]
            if let adguardSource {
                let root = model.systemBrowserHost.root
                try FileManager.default.createDirectory(at: root.appendingPathComponent("UnpackedExtensions"), withIntermediateDirectories: true)
                try Data("Orvlet isolated browser profile\n".utf8).write(to: root.appendingPathComponent(".orvlet-profile"))
                try FileManager.default.copyItem(at: URL(fileURLWithPath: adguardSource), to: root.appendingPathComponent("UnpackedExtensions/AdGuard"))
            }
            guard let page = browser.systemPage else { throw AppError.message("System browser backend was not selected") }
            let first = try await browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?task=one#saved"])
            if let pid = model.systemBrowserHost.process?.processIdentifier { browserProcesses.insert(pid) }
            try require((first["url"] as? String)?.contains("task=one") == true, "The default browser loads a real task page")
            try require(page.currentURL?.fragment == "saved", "External open retains the anchor on the initial Chromium navigation")
            try require(page.historyItems.back == nil && page.historyItems.forward == nil,
                "A newly opened page has no previous or next website")
            _ = try await page.evaluate("history.pushState({}, '', '#section2'); true")
            for _ in 0..<40 where page.historyItems.back == nil { try await Task.sleep(for: .milliseconds(25)) }
            try require(page.historyItems.back != nil && page.historyItems.forward == nil,
                "A new in-page section makes Back available")
            _ = try await browser.action(["action": "back"])
            try require(page.currentURL?.fragment == "saved" && page.historyItems.back == nil && page.historyItems.forward != nil,
                "Back returns to the original section and enables Forward")
            _ = try await browser.action(["action": "forward"])
            try require(page.currentURL?.fragment == "section2" && page.historyItems.forward == nil,
                "Forward restores the section and disables itself at the end of history")
            let ua = try await page.evaluate("navigator.userAgent") as? String ?? ""
            try require(ua.contains("Chrome/"), "The renderer is Chromium, not the WebKit display shell")
            try require(model.systemBrowserHost.root.path.contains("orvlet-browser-test-"), "Browser checks use an isolated temporary profile")
            try require(try await page.evaluate("typeof window.__orvletPlaybackRequested === 'undefined'") as? Bool == true,
                "Web content cannot call the native playback-gesture binding")
            if adguardSource != nil {
                try await Task.sleep(for: .seconds(3))
                let base = try await model.systemBrowserHost.start()
                let (data, _) = try await model.systemBrowserHost.http.data(from: base.appendingPathComponent("json/list"))
                let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                guard let background = targets.first(where: { ($0["url"] as? String)?.hasSuffix("/pages/background.js") == true }),
                    let socket = (background["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else {
                    throw AppError.message("AdGuard background worker did not load in the real browser")
                }
                let worker = BrowserDevTools(url: socket, session: model.systemBrowserHost.http)
                defer { worker.close() }
                let result = try await worker.call("Runtime.evaluate", ["expression": "chrome.declarativeNetRequest.getEnabledRulesets()", "awaitPromise": true, "returnByValue": true])
                let rules = (result["result"] as? [String: Any])?["value"] as? [String] ?? []
                try require(rules.contains("ruleset_2"), "Official AdGuard initializes its background worker and base filtering rules")
            }
            let blocked = try await page.evaluate("(async()=>{try{await fetch('/pl/_ajax/ablck.php');return false}catch{return true}})()") as? Bool
            try require(blocked == (adguardSource != nil), adguardSource == nil
                ? "The unfiltered local control request succeeds"
                : "Official AdGuard actually blocks the controlled local advertising request")
            _ = try await page.evaluate("document.querySelector('audio').muted=true;document.querySelector('audio').volume=0;true")
            browser.setUserPlaybackPaused(false, origin: "system_browser_check")
            await browser.applyPlaybackPolicy()
            let playing = try await browser.action(["action": "media", "operation": "play"])
            try require(await page.mediaState() == .playing, "External open detects playing media in the source renderer")
            try require(playing["playing"] as? Bool == true, "Playback controls operate the background renderer on muted local media")
            browser.setUserPlaybackPaused(true, origin: "system_browser_check")
            await browser.applyPlaybackPolicy()
            try require(try await page.evaluate("document.querySelector('audio').paused") as? Bool == true,
                "The shared playback gate pauses the real browser media")
            _ = try await page.evaluate("""
                document.body.innerHTML='<main style="padding:32px;font:18px system-ui"><h1>Task browser</h1><input id="checkInput" aria-label="Message" style="width:240px"><button id="checkButton" style="margin:16px">Run</button><p id="result">Ready</p></main>';
                document.getElementById('checkButton').onclick=e=>{document.getElementById('result').textContent='Clicked';window.realClick=e.isTrusted};true
                """)
            let second = BrowserController(model: model)
            other = second
            second.setUserPlaybackPaused(true, origin: "system_browser_check")
            _ = try await second.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?task=two"])
            _ = try await second.evaluate("window.taskIsolation='second'; true")
            _ = try await second.evaluate("document.cookie='orvlet_persistence=fixture; Max-Age=86400; Path=/';true")
            try require(try await page.evaluate("document.cookie.includes('orvlet_persistence=fixture')") as? Bool == true,
                "Separate task windows share the persistent profile's login cookies")
            try require(try await browser.evaluate("window.taskIsolation===undefined") as? Bool == true,
                "Each task has an independent DOM and execution target")
            _ = try await page.evaluate("document.getElementById('checkInput').focus();true")
            let canvas = SystemBrowserCanvas(page: page)
            canvas.presented = true
            canvas.insertText("你好 Orvlet", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(400))
            try require(try await page.evaluate("document.getElementById('checkInput').value") as? String == "你好 Orvlet",
                "Native text input reaches the real browser, including Unicode")
            let bounds = try await page.evaluate("(()=>{const r=document.getElementById('checkButton').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()") as! [String: Double]
            _ = try await page.client!.call("Input.dispatchMouseEvent", ["type": "mousePressed", "x": bounds["x"]!, "y": bounds["y"]!, "button": "left", "clickCount": 1])
            _ = try await page.client!.call("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": bounds["x"]!, "y": bounds["y"]!, "button": "left", "clickCount": 1])
            try require(try await page.evaluate("window.realClick===true && document.getElementById('result').textContent==='Clicked'") as? Bool == true,
                "Pointer input is a trusted click in the displayed browser page")
            _ = try await page.evaluate("document.getElementById('checkInput').focus();true")
            canvas.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            canvas.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(200))
            try require(try await page.evaluate("document.getElementById('checkInput').value.endsWith('输入')") as? Bool == true,
                "IME composition commits text to the real browser field")
            let raw = try await browser.screenshot()
            try require(Data(base64Encoded: raw).flatMap(NSImage.init(data:)) != nil, "Task screenshots come from the live Chromium renderer")

            model.selectedTaskID = browser.id
            model.collapsed = false
            model.webExpanded = true
            model.rememberWebSize(NSSize(width: 620, height: 400))
            let size = model.windowSize
            let compact = model.compactSize
            model.shellLayout = ShellLayout(
                frame: NSRect(x: 0, y: 0, width: size.width + compact.width, height: size.height),
                compact: NSRect(x: size.width, y: size.height - compact.height, width: compact.width, height: compact.height),
                content: NSRect(origin: .zero, size: size), edge: .left)
            let window = NSPanel(contentRect: NSRect(x: -16000, y: -16000, width: size.width + compact.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel = window
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            for _ in 0..<60 {
                if page.frame != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(page.frame != nil, "Opening the source view starts live frames inside Orvlet")
            try await Task.sleep(for: .milliseconds(300))
            let cssWidth = try await page.evaluate("innerWidth") as? Double ?? 0
            try require(cssWidth <= size.width && cssWidth > size.width - 12,
                        "Chromium lays out the narrow page at the width of the source window")
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-system-browser-inline.png")
            checks += try await SystemBrowserLatencyCheck.run(page)
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-system-browser-responsive.png")
            let manager = try HandoffSource(taskID: browser.id, destination: URL(string: "chrome://extensions/")!, model: model, browserManager: true)
            defer { manager.close() }
            window.contentView = NSHostingView(rootView: HandoffSourceView(source: manager))
            window.contentView?.layoutSubtreeIfNeeded()
            for _ in 0..<80 {
                if manager.systemBrowser?.systemPage?.frame != nil,
                    ((try? await manager.systemBrowser?.evaluate("location.href")) as? String)?.contains("://extensions") == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let managerURL = try await manager.systemBrowser?.evaluate("location.href") as? String ?? ""
            try require(managerURL.contains("://extensions"), "The real browser extension manager opens inside Orvlet")
            try await Task.sleep(for: .milliseconds(300))
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-system-browser-extensions.png")
            manager.close()
            for dark in [false, true] {
                window.setContentSize(NSSize(width: 450, height: 230))
                window.contentView = NSHostingView(rootView:
                    SystemBrowserSettings(model: model, engine: .constant(.systemBrowser)).padding(20)
                        .frame(width: 450, height: 230).background(dark ? Color.black : Color.white)
                        .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView?.layoutSubtreeIfNeeded()
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-system-browser-settings-\(dark ? "dark" : "light").png")
            }
            window.orderOut(nil)
            page.setVisible(false, size: size)
            _ = try await page.evaluate("window.backgroundValue=42; true")
            try require(try await page.evaluate("window.backgroundValue") as? Int == 42, "Collapsing the viewport keeps the page alive")
            let pending = Task { try await page.client!.call("Runtime.evaluate", ["expression": "new Promise(()=>{})", "awaitPromise": true]) }
            try await Task.sleep(for: .milliseconds(100))
            pending.cancel()
            var cancelled = false
            do { _ = try await pending.value } catch is CancellationError { cancelled = true }
            try require(cancelled, "Cancelling an outstanding browser command completes its continuation")
            browser.dispose()
            try require(try await second.evaluate("window.taskIsolation") as? String == "second", "Closing one task leaves another task's page intact")
            try require(try await second.evaluate("document.cookie.includes('orvlet_persistence=fixture')") as? Bool == true,
                "The fixture login cookie is still present immediately before shutdown")
            let closingProcess = model.systemBrowserHost.process
            let shutdownStarted = Date()
            await model.systemBrowserHost.shutdown()
            print("Browser shutdown seconds:", Date().timeIntervalSince(shutdownStarted),
                "running:", closingProcess?.isRunning == true,
                "reason:", closingProcess?.isRunning == false ? closingProcess?.terminationReason.rawValue ?? -1 : -1)
            try require(second.sourceAccessIssue == nil, "Normal browser shutdown does not persist a false task failure")
            _ = try await second.action(["action": "reload"])
            if let pid = model.systemBrowserHost.process?.processIdentifier { browserProcesses.insert(pid) }
            try require(second.currentURL?.query == "task=two", "Reload after shutdown reconnects the same task URL")
            try require(try await second.evaluate("document.cookie.includes('orvlet_persistence=fixture')") as? Bool == true,
                "The independent browser profile preserves persistent login cookies across restart")
            second.dispose()
            model.systemBrowserHost.stop()
            let reconnect = BrowserController(model: model)
            other = reconnect
            reconnect.setUserPlaybackPaused(true, origin: "system_browser_check")
            _ = try await reconnect.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?restarted"])
            if let pid = model.systemBrowserHost.process?.processIdentifier { browserProcesses.insert(pid) }
            try require(reconnect.currentURL?.query == "restarted", "A stopped private browser can restart without reusing a dead connection")
            reconnect.dispose()
            model.systemBrowserHost.stop()
            checks += try profileChecks()
            try require(NSApp.windows.allSatisfy { !$0.isVisible }, "System browser checks leave no visible windows")
            let ownedProcesses = browserProcesses.union([ProcessInfo.processInfo.processIdentifier])
            if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier { activations.insert(frontmost) }
            try require(activations.isDisjoint(with: ownedProcesses),
                "No test app or owned browser takes desktop focus during background checks")
            try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: URL(fileURLWithPath: "/tmp/orvlet-system-browser-checks.json"))
            defaults.removePersistentDomain(forName: suite)
            exit(0)
        } catch {
            panel?.orderOut(nil)
            browser.dispose()
            other?.dispose()
            model.systemBrowserHost.stop()
            try? JSONSerialization.data(withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription]).write(to: URL(fileURLWithPath: "/tmp/orvlet-system-browser-checks.json"))
            print("FAILED", error.localizedDescription)
            defaults.removePersistentDomain(forName: suite)
            exit(1)
        }
    }
    static func profileChecks() throws -> [String] {
        var checks: [String] = []
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("orvlet-profile-check-" + UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let userData = base.appendingPathComponent("source")
        let profile = userData.appendingPathComponent("Default")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{\"profile\":{\"info_cache\":{\"Default\":{\"name\":\"Local test\"}}},\"os_crypt\":{\"encrypted_key\":\"fixture-only\"}}".utf8).write(to: userData.appendingPathComponent("Local State"))
        try Data("never import".utf8).write(to: profile.appendingPathComponent("Login Data"))
        try Data("never import".utf8).write(to: profile.appendingPathComponent("History"))
        let enabledID = String(repeating: "a", count: 32)
        let disabledID = String(repeating: "b", count: 32)
        for id in [enabledID, disabledID] {
            let directory = profile.appendingPathComponent("Extensions/\(id)/1.0")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\"name\":\"Fixture\",\"version\":\"1.0\",\"manifest_version\":3}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        }
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": [
            enabledID: ["path": enabledID + "/1.0", "state": 1],
            disabledID: ["path": disabledID + "/1.0", "state": 0]]]]).write(to: profile.appendingPathComponent("Secure Preferences"))
        var db: OpaquePointer?
        guard sqlite3_open(profile.appendingPathComponent("Cookies").path, &db) == SQLITE_OK else { throw AppError.message("Fixture DB failed") }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE cookies (name TEXT); INSERT INTO cookies VALUES ('fixture');", nil, nil, nil)
        let available = BrowserProfileImporter.profiles(in: userData)
        try StateMachineCheck.require(available.count == 1, "Only recognized browser profile directories are offered", &checks)
        let staging = try BrowserProfileImporter.stage(profile: available[0], applicationData: userData, destination: base.appendingPathComponent("target"))
        defer { try? fm.removeItem(at: staging) }
        try StateMachineCheck.require(fm.fileExists(atPath: staging.appendingPathComponent("Default/Cookies").path)
            && !fm.fileExists(atPath: staging.appendingPathComponent("Default/Login Data").path)
            && !fm.fileExists(atPath: staging.appendingPathComponent("Default/History").path),
            "Profile import snapshots cookies while excluding saved passwords and history", &checks)
        try StateMachineCheck.require(fm.fileExists(atPath: staging.appendingPathComponent("UnpackedExtensions/\(enabledID)/manifest.json").path)
            && !fm.fileExists(atPath: staging.appendingPathComponent("UnpackedExtensions/\(disabledID)").path),
            "Imported extension code is independent and disabled extensions stay disabled", &checks)
        var copy: OpaquePointer?, query: OpaquePointer?
        sqlite3_open(staging.appendingPathComponent("Default/Cookies").path, &copy)
        defer { sqlite3_finalize(query); sqlite3_close(copy) }
        sqlite3_prepare_v2(copy, "SELECT COUNT(*) FROM cookies", -1, &query, nil)
        let status = sqlite3_step(query)
        try StateMachineCheck.require(status == SQLITE_ROW && sqlite3_column_int(query, 0) == 1,
            "Cookie import includes committed WAL data without closing the source database", &checks)
        let cookiesOnly = try BrowserProfileImporter.stage(profile: available[0], applicationData: userData,
            destination: base.appendingPathComponent("cookies-only"), includeExtensions: false)
        defer { try? fm.removeItem(at: cookiesOnly) }
        try StateMachineCheck.require(fm.fileExists(atPath: cookiesOnly.appendingPathComponent("Default/Cookies").path)
            && !fm.fileExists(atPath: cookiesOnly.appendingPathComponent("UnpackedExtensions").path),
            "Chrome's cookies-only import does not claim unsupported extension loading", &checks)
        return checks
    }
}
#endif
