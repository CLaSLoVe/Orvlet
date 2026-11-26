#if DEBUG
import AppKit
import SwiftUI

/// Give the renderer a local key-window state without asking WindowServer to
/// change keyboard focus, activate the app, or disturb the user's active app.
private final class NativeInputCheckPanel: NSPanel {
    var simulatedKey = false
    override var isKeyWindow: Bool { simulatedKey }
}

/// Real native Chromium, isolated profile, nonactivating windows outside every screen.
@MainActor
enum NativeChromiumCheck {
    static func start() async {
        setbuf(stdout, nil)
        var checks: [String] = []
        let suite = "orvlet-native-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.reduceMotion = true
        var activated = false
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == ProcessInfo.processInfo.processIdentifier { activated = true }
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer); defaults.removePersistentDomain(forName: suite) }
        var second: BrowserController?
        var panel: NSPanel?
        func require(_ condition: Bool, _ label: String) throws { try StateMachineCheck.require(condition, label, &checks) }
        func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
        do {
            try require(NativeChromium.available && model.usesNativeBrowser, "Built-in uses the compiled native Chromium backend")
            try require(NSApp.windows.allSatisfy { !$0.isVisible }, "Native checks start without showing a window")
            model.settings.allowAgents = false
            model.settings.restoreLastSession = true
            let autoplay = CommandLine.arguments.contains("--verify-native-disabled")
            model.settings.resumePlaybackOnLaunch = autoplay
            let saved = SavedSession(url: "http://127.0.0.1:19244/fixture?native=one", title: "Saved recording",
                                     volume: 0.37, listening: true, wasPlaying: true)
            model.sessions.put(saved)
            model.start()
            let id: UUID
            if autoplay {
                try require(model.restoringSession, "Explicit resume-on-launch starts restoring the playing session")
                await model.restoreTask?.value
                id = model.browser.id
            } else {
                guard let restoredID = model.selectedTaskID else { throw AppError.message("Missing saved card") }
                id = restoredID
                guard let idlePage = model.browser.systemPage else { throw AppError.message("Missing native page") }
                let hiddenSource = NSHostingView(rootView: BrowserPageSurface(page: idlePage, visible: false))
                let idlePanel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 80),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                idlePanel.contentView = hiddenSource
                idlePanel.orderBack(nil)
                hiddenSource.layoutSubtreeIfNeeded()
                try await settle()
                idlePanel.orderOut(nil)
                try require(!NativeChromium.running && idlePage.nativeBrowser == nil &&
                    model.quickMediaTasks.contains { $0.id == id && !$0.playing },
                    "Launching with saved playback restores its controls while the hidden source and Keychain stay idle")
                if CommandLine.arguments.contains("--verify-native-persistence") {
                    model.controlMedia(id, operation: "toggle")
                    let deadline = Date().addingTimeInterval(30)
                    while model.sideTasks.first(where: { $0.id == id })?.playing != true && Date() < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try require(model.browser.id == id && model.sideTasks.first(where: { $0.id == id })?.playing == true,
                        "Play on a dormant capsule starts the original task and keeps it available for saving progress")
                    try await model.performMusicControl(id, operation: "pause")
                } else {
                    try await model.prepareTaskSource(id)
                }
            }
            let browser = model.browser
            guard let page = browser.systemPage else { throw AppError.message("Missing restored native page") }
            try require(browser.id == id && NativeChromium.running && NSApp.delegate is AppDelegate,
                "Opening the saved task starts the selected browsing session and preserves its identity and app delegate")
            try require(try await page.evaluate("document.querySelector('audio').paused") as? Bool == !autoplay,
                "Restored playback follows the user's resume-on-launch preference")
            try require(try await page.evaluate("Math.abs(document.querySelector('audio').volume - 0.37) < 0.01") as? Bool == true,
                "Restoration preserves the saved media volume")
            guard let native = page.nativeBrowser else { throw AppError.message("Missing native Chromium view") }
            try require(!native.view.subviews.isEmpty, "A real Chromium child view is embedded in the app process")
            try require(try await page.evaluate("navigator.userAgent.includes('Chrome/')") as? Bool == true, "The built-in page runs Chromium")
            try require(model.nativeBrowserHost.root.path.contains("orvlet-native-"), "Native checks use an isolated profile")
            let restarted = CommandLine.arguments.contains("--verify-native-persistence")
            let disabled = CommandLine.arguments.contains("--verify-native-disabled")
            let retained = CommandLine.arguments.contains("--verify-saved-logins")
            let store = model.nativeExtensions
            try require(store.keepLogins == disabled, "Website login persistence requires explicit opt-in")
            for expression in ["document.cookie.includes('orvlet_native=retained')", "document.cookie.includes('orvlet_session=retained')", "localStorage.orvlet_native==='retained'"] {
                try require(try await page.evaluate(expression) as? Bool == retained, "Site storage follows the selected session mode")
            }
            _ = try await page.evaluate("document.cookie='orvlet_native=retained; Max-Age=86400; Path=/';document.cookie='orvlet_session=retained; Path=/';localStorage.orvlet_native='retained';true")
            try await settle()
            if !disabled {
                try require(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Default").path),
                    "Guest browsing leaves the saved Chromium profile untouched")
            }
            checks += try await SiteMemoryCheck.run(browserOnly: true)
            let shouldFilter = restarted && !disabled
            try require(try await page.evaluate("document.documentElement.dataset.nativeExtension==='installed'") as? Bool == shouldFilter,
                "Only installed and enabled extensions run content scripts")
            try require(try await page.evaluate("(async()=>{try{await fetch('/pl/_ajax/ablck.php');return false}catch{return true}})()") as? Bool == shouldFilter,
                "User-installed network rules apply only while enabled")
            if !restarted {
                checks += try await checkYouTubeAdSkipping(model)
                try require(store.entries.isEmpty, "Fresh profiles contain no preinstalled extensions")
                let oldProfile = store.root.appendingPathComponent("MigrationFixture")
                try FileManager.default.createDirectory(at: oldProfile, withIntermediateDirectories: false)
                let imported = NativeExtensions.Entry(id: "user-extension", name: "User choice", version: "1", enabled: false, digest: "local")
                let bundled = NativeExtensions.Entry(id: "old-package", name: "Previous default", version: "1", enabled: true, digest: "bundled")
                try JSONEncoder().encode([imported, bundled]).write(to: oldProfile.appendingPathComponent("extensions.json"))
                try NativeExtensions.removeBundledRegistrations(in: oldProfile)
                try require(NativeExtensions(root: oldProfile).entries == [imported],
                    "Upgrade preserves the user's installed extensions and drops automatic registrations")
                let source = model.nativeBrowserHost.root.appendingPathComponent("ImportFixture")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let manifest: [String: Any] = ["manifest_version": 3, "name": "Local filtering check", "version": "1.0",
                    "permissions": ["storage", "declarativeNetRequest"], "host_permissions": ["http://127.0.0.1/*"],
                    "options_page": "options.html",
                    "declarative_net_request": ["rule_resources": [["id": "local_rules", "enabled": true, "path": "rules.json"]]],
                    "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"]]]
                try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
                try Data(#"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/pl/_ajax/ablck.php","resourceTypes":["xmlhttprequest"]}}]"#.utf8).write(to: source.appendingPathComponent("rules.json"))
                try Data("<title>Extension settings fixture</title>".utf8).write(to: source.appendingPathComponent("options.html"))
                try Data("document.documentElement.dataset.nativeExtension='installed';".utf8).write(to: source.appendingPathComponent("content.js"))
                try store.prepare(source)
                try require(store.pending?.permissions.contains("storage") == true && store.entries.isEmpty,
                    "Import shows requested permissions before installation")
                try store.install()
                try require(store.entries.count == 1 && store.pending == nil && store.restartRequired,
                    "Installation persists the reviewed package")
                var rejected = false
                do { try store.prepare(source) } catch { rejected = true }
                try require(rejected, "An identical extension package cannot be installed twice")
                try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked.js"), withDestinationURL: source.appendingPathComponent("content.js"))
                rejected = false
                do { _ = try NativeExtensions.fingerprint(source) } catch { rejected = true }
                try require(rejected, "Extension import rejects symbolic links before copying")
            }
            if disabled {
                try require(store.entries.count == 1 && store.entries.first?.enabled == false, "Disabled state survives restart")
                if retained, let entry = store.entries.first {
                    try store.remove(entry.id)
                    try require(store.entries.isEmpty, "Users can remove an installed extension")
                }
                browser.dispose()
                await model.nativeBrowserHost.shutdown()
                NativeChromium.stopApplication {
                    try? JSONSerialization.data(withJSONObject: ["ok": !NativeChromium.running && !activated, "checks": checks]).write(to: URL(fileURLWithPath: "/tmp/orvlet-native-browser-checks.json"))
                    exit(NativeChromium.running || activated ? 1 : 0)
                }
                return
            }
            _ = try await page.evaluate("document.querySelector('audio').muted=true;true")
            browser.setUserPlaybackPaused(false, origin: "native_check")
            await browser.applyPlaybackPolicy()
            let playing = try await browser.action(["action": "media", "operation": "play"])
            try require(playing["playing"] as? Bool == true, "Muted local playback works while the native view is parked in the background")
            if !restarted {
                checks += try await checkReminderAudio(model, page: page, owner: id)
            }
            browser.setUserPlaybackPaused(true, origin: "native_check")
            await browser.applyPlaybackPolicy()
            try require(try await page.evaluate("document.querySelector('audio').paused") as? Bool == true, "Native playback respects the shared pause state")
            _ = try await page.evaluate("""
                document.body.innerHTML='<main style="padding:32px;font:18px system-ui;background:#faf9fe;color:#282631;height:1400px"><h1>Native Chromium</h1><input id="checkInput" aria-label="Message" style="width:240px;height:32px"><button id="checkButton" style="margin:16px;height:36px">Run</button><p id="result">Ready</p></main>';
                document.getElementById('checkButton').onclick=e=>{document.getElementById('result').textContent='Clicked';window.realClick=e.isTrusted};true
                """)
            if !restarted {
                let observed = try await browser.observe()
                let action = BoundCardAction(id: "runCard", binding: PageBinding(action: "click", role: "button", name: "Run"), compactLabel: "Run")
                let plan = try SurfacePlan(components: [], width: 300, height: 130,
                    markup: CardMarkup(html: "<button data-action='runCard'>Run</button>", css: ""), actions: [action]).validated(observation: observed)
                guard let selected = plan.actions?.first, let boundPage = selected.compactPageURL else {
                    throw AppError.message("Missing the observed page identity on a generated capsule action")
                }
                var arguments = selected.binding.dictionary
                arguments["expectedPage"] = boundPage + "#other"
                var rejected = false
                do { _ = try await browser.action(arguments) } catch { rejected = true }
                let untouched = try await page.evaluate("document.getElementById('result').textContent==='Ready'") as? Bool
                try require(rejected && untouched == true, "A generated capsule cannot apply its click to a different page")
                arguments["expectedPage"] = boundPage
                _ = try await browser.action(arguments)
                try require(try await page.evaluate("document.getElementById('result').textContent==='Clicked'") as? Bool == true,
                            "The generated web capsule runs its registered click on the observed page")
            }
            let window = NativeInputCheckPanel(contentRect: NSRect(x: -16000, y: -16000, width: 640, height: 420),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel = window
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            let viewport = NativeChromiumViewport(page: page, browser: native)
            viewport.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
            viewport.presented = true
            window.contentView = viewport
            window.orderBack(nil)
            viewport.layoutSubtreeIfNeeded()
            try await settle()
            try require(native.view.window === window, "Opening the page reparents the same live native view into Orvlet")
            try require(page.frame == nil, "Native presentation does not start a JPEG screencast")
            let point = try await page.evaluate("(()=>{const r=document.getElementById('checkButton').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()") as! [String: Double]
            let local = NSPoint(x: point["x"]!, y: native.view.bounds.height - point["y"]!)
            let inWindow = native.view.convert(local, to: nil)
            guard let hit = window.contentView?.hitTest(window.contentView!.convert(inWindow, from: nil)) else { throw AppError.message("Native hit testing found no content") }
            let began = ContinuousClock.now
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
            }
            var clicked = false
            for _ in 0..<100 {
                if try await page.evaluate("window.realClick===true && document.getElementById('result').textContent==='Clicked'") as? Bool == true { clicked = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(clicked, "Native Cocoa mouse events click the correct element without CDP input forwarding")
            print("Native input observed through CDP after: \(began.duration(to: .now))")
            _ = window.makeFirstResponder(nil)
            window.simulatedKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            native.focusRenderer()
            _ = try await page.evaluate("document.getElementById('checkInput').focus();true")
            try await settle()
            guard let input = hit as? NSTextInputClient else { throw AppError.message("Chromium content does not implement native text input") }
            input.insertText("你好 Orvlet", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle()
            print("Native text diagnostics: \(type(of:hit)), first responder \(window.firstResponder === hit), key \(window.isKeyWindow), \(try await page.evaluate("({value:document.getElementById('checkInput').value,active:document.activeElement?.id,focus:document.hasFocus()})") ?? "nil")")
            try require(try await page.evaluate("document.getElementById('checkInput').value") as? String == "你好 Orvlet",
                "The Chromium native text client accepts Unicode without a remote input queue")
            input.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            input.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle()
            try require(try await page.evaluate("document.getElementById('checkInput').value.endsWith('输入')") as? Bool == true, "Native IME composition commits inside Chromium")
            let screenshot = try await browser.screenshot()
            try Data(base64Encoded: screenshot)!.write(to: URL(fileURLWithPath: "/tmp/orvlet-native-page.png"))
            if let bitmap = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds) {
                viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/orvlet-native-view.png"))
            }
            let initialFrame = window.frame
            for _ in 0..<5 {
                viewport.presented = false; viewport.needsLayout = true; viewport.layoutSubtreeIfNeeded()
                try require(native.view.window !== window, "Hiding parks the native view without disposing its page")
                viewport.presented = true; viewport.needsLayout = true; viewport.layoutSubtreeIfNeeded()
            }
            try require(window.frame == initialFrame && native.view.window === window, "Repeated page/card switches preserve the outer window size")
            try require(try await page.evaluate("document.getElementById('checkInput').value") as? String == "你好 Orvlet输入", "Page state survives repeated native-view reparenting")
            for size in [NSSize(width: 420, height: 300), NSSize(width: 780, height: 510), NSSize(width: 640, height: 420)] {
                window.setContentSize(size); viewport.needsLayout = true; viewport.layoutSubtreeIfNeeded()
            }
            try await settle()
            try require(abs((try await page.evaluate("innerWidth") as? Double ?? 0) - viewport.bounds.width) <= 1,
                "Native compositor dimensions match the visible viewport after resizing")
            // A recent trusted click grants a short-lived activation token.
            // Wait for it to expire before testing an unsolicited popup.
            for _ in 0..<40 {
                if try await page.evaluate("navigator.userActivation.isActive") as? Bool != true { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            _ = try await page.evaluate("window.open('/fixture?popup=blocked');alert('background dialog');true")
            try await settle()
            try require(try await page.evaluate("location.search.includes('native=one')") as? Bool == true, "Automatic popups and dialogs cannot open desktop windows or replace the task")
            let other = BrowserController(model: model)
            second = other
            other.setUserPlaybackPaused(true, origin: "native_check")
            _ = try await other.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?native=two"])
            try require(try await other.evaluate("document.cookie.includes('orvlet_native=retained') && typeof window.realClick==='undefined'") as? Bool == true,
                "Independent native pages share login state without sharing their DOM")
            guard let otherPage = other.systemPage else { throw AppError.message("Missing second page") }
            if restarted, let entry = store.entries.first, let options = try store.pageURL(entry) {
                _ = try await otherPage.client?.call("Page.navigate", ["url": options.absoluteString])
                try await settle()
                try require(try await other.evaluate("document.title==='Extension settings fixture'") as? Bool == true,
                    "The installed extension opens its own options inside Orvlet")
            }
            // The next fixture is a browsing task with a custom source card.
            model.endBackgroundListening(clearTaskIntent: true)
            model.settings.compactLayout = .vertical
            model.settings.appearance = .light
            var task = SideTask(id: browser.id, kind: .web, title: "Native Chromium")
            // Live page observations refresh web cards from their source-bound SurfacePlan.
            var plan = SurfacePlan.webpage
            plan.markup = CardMarkup(html: "<h2>Native Chromium</h2><p>Saved page</p>", compactHTML: "Native Chromium",
                                     css: "h2{font-size:18px}", height: 100)
            task.sourceURL = model.webURL
            task.plan = plan
            model.surface = plan
            task.prefersSource = false
            task.mediaPrimary = false
            model.sideTasks = [task]
            model.selectedTaskID = task.id
            model.hasCustomSurface = true
            let anchor = NSRect(x: -15000, y: -15000, width: model.compactSize.width, height: model.compactSize.height)
            model.onResize = { _ in
                let layout = ShellLayout.place(anchor: anchor, content: model.shellContentSize, orientation: .vertical,
                    screen: NSRect(x: -18000, y: -18000, width: 5000, height: 5000), edge: .left)
                model.shellLayout = layout
                window.setFrame(layout.frame, display: false)
            }
            model.selectTask(task.id, expanded: true, preferSource: false)
            let hosting = NSHostingView(rootView: ContentView(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            try await settle()
            window.contentView?.layoutSubtreeIfNeeded()
            let cardFrame = window.frame
            let firstCardSize = model.windowSize
            model.upsertWebTask()
            try require(model.selectedSideTask?.presentation.html == plan.markup?.html && model.windowSize == firstCardSize,
                        "A live source refresh retains the card design installed after page load")
            model.openTaskFromDoubleClick(task.id)
            try await settle()
            window.contentView?.layoutSubtreeIfNeeded()
            try require(model.shellLayout.content.size == model.preferredWebSize && native.view.window === window,
                "Double-click attaches the native browser at the saved source dimensions")
            model.rememberWebSize(NSSize(width: 620, height: 420))
            model.onResize?(model.windowSize)
            try await settle()
            let sourceFrame = window.frame
            try require(sourceFrame.width > cardFrame.width && model.shellLayout.content.size == NSSize(width: 620, height: 420),
                        "Resizing the source expands the Chromium viewport independently")
            try await snapshot(window, browser: browser, path: "/tmp/orvlet-native-shell.png")
            model.selectTask(task.id, expanded: true, preferSource: false)
            try await settle()
            try require(window.frame == cardFrame, "Returning from the native browser restores the original card frame (\(cardFrame) → \(window.frame), detail \(firstCardSize) → \(model.windowSize))")
            model.openTaskFromDoubleClick(task.id)
            try await settle()
            try require(native.view.window === window && window.frame == sourceFrame, "Reopening the source reattaches its native renderer at the remembered size")
            let stale = NativeChromiumViewport(page: page, browser: native)
            stale.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
            stale.presented = true
            stale.layoutSubtreeIfNeeded()
            try require(native.view.window === window, "A detached old viewport cannot steal a renderer from the current source")
            let settingsPanel = NSPanel(contentRect: NSRect(x: -14000, y: -14000, width: 420, height: 280),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            settingsPanel.isReleasedWhenClosed = false
            settingsPanel.contentView = NSHostingView(rootView: SystemBrowserSettings(model: model, engine: .constant(.builtIn))
                .padding(24).frame(width: 420, height: 280, alignment: .topLeading).background(CalmVisualStyle.windowFill(.light)))
            settingsPanel.orderBack(nil)
            try await settle()
            try await SideScreenCheck.snapshot(settingsPanel, path: "/tmp/orvlet-native-settings.png")
            settingsPanel.orderOut(nil)
            model.onResize = nil
            _ = try await page.evaluate("""
                document.body.insertAdjacentHTML('beforeend','<audio muted loop preload="auto" src="/tone.wav"></audio>'); true
                """)
            browser.setUserPlaybackPaused(false, origin: "native_check")
            await browser.applyPlaybackPolicy()
            let resumed = try await browser.action(["action": "media", "operation": "play"])
            try require(resumed["playing"] as? Bool == true, "The deletion fixture plays muted audio in its own Chromium page")
            model.persistSideTasks()
            guard let recording = model.work.view(browser.id)?.selected else { throw AppError.message("Missing recording view") }
            let alias = try model.presentWork([recording], layout: .single, title: "Recording", destination: UUID())[0]
            if restarted {
                try model.prepareBrowserForNewTask()
                try require(model.parkedBrowsers[browser.id] === browser, "The restart pass exercises deletion of a parked player")
            }
            model.dismissTask(alias)
            model.closeTask(browser.id)
            try await settle()
            let stillPlaying = try await page.evaluate("!document.querySelector('audio').paused") as? Bool
            try require(!native.closed && model.work.view(alias)?.hidden == true && stillPlaying == true,
                "Deleting one playback card keeps the hidden second card's music playing")
            model.closeTask(alias)
            try await settle()
            try require(native.closed && browser.disposed && model.playbackCoordinator.owner != browser.id &&
                model.musicBrowser(browser.id) == nil && !model.listedTasks.contains { $0.id == alias || $0.id == browser.id },
                "Deleting the last playback card stops its renderer and releases audio ownership")
            guard let source = model.work.artifact(recording)?.source else { throw AppError.message("Missing archived recording source") }
            model.settings.resumePlaybackOnLaunch = true
            model.restoreSessionOnLaunch(SavedSession(url: source, title: "Recording", listening: true, wasPlaying: true))
            try require(!model.restoringSession && model.dormantLaunchSession == nil && model.musicBrowser(browser.id) == nil,
                "A legacy playing session cannot reopen a deleted recording")
            try require(native.closed && window.isVisible, "Closing an embedded page does not close its Orvlet host window")
            try require(try await other.evaluate("document.readyState==='complete'") as? Bool == true, "Closing one native task leaves another responsive")
            let staleConnection = otherPage.client
            let oldRenderer = otherPage.nativeBrowser
            otherPage.disconnectNativePage()
            _ = try await other.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?native=reconnected"])
            let replacement = otherPage.nativeBrowser
            staleConnection?.failed?(AppError.message("Delayed failure from an old connection"))
            try await settle()
            try require(oldRenderer?.closed == true && replacement != nil && otherPage.nativeBrowser === replacement,
                "A native page reconnects without an old connection failure closing its replacement")
            try require(try await other.evaluate("location.search.includes('native=reconnected')") as? Bool == true,
                "The replacement native page remains responsive after a stale failure")
            if restarted, let entry = store.entries.first {
                try store.setEnabled(entry.id, false)
                try store.setKeepLogins(true)
            }
            other.dispose()
            window.orderOut(nil)
            await model.nativeBrowserHost.shutdown()
            try require(!activated, "Native regression checks never activate Orvlet")
            NativeChromium.stopApplication {
                do {
                    try require(!NativeChromium.running, "Native browser views and sandboxed helpers shut down cleanly")
                    try require(NSApp.windows.allSatisfy { !$0.isVisible }, "Native regression checks leave no visible windows")
                    try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: URL(fileURLWithPath: "/tmp/orvlet-native-browser-checks.json"))
                    exit(0)
                } catch { exit(1) }
            }
        } catch {
            model.browser.dispose(); second?.dispose(); panel?.orderOut(nil)
            await model.nativeBrowserHost.shutdown()
            try? JSONSerialization.data(withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription]).write(to: URL(fileURLWithPath: "/tmp/orvlet-native-browser-checks.json"))
            fputs("Native check failed: \(error.localizedDescription)\n", stderr)
            NativeChromium.stopApplication { exit(1) }
        }
    }

    // Fulfill this task's navigation locally so the regression needs neither an ad impression nor a live account.
    private static func checkYouTubeAdSkipping(_ model: AppModel) async throws -> [String] {
        let browser = BrowserController(model: model)
        defer { browser.dispose() }
        guard let page = browser.systemPage else { throw AppError.message("Missing native player") }
        try await page.ready()
        guard let client = page.client else { throw AppError.message("Missing fixture connection") }
        let markup = """
            <title>Chillhop Café</title><div id="movie_player" class="html5-video-player ad-showing">
            <video></video><button class="ytp-skip-ad-button" disabled onclick="wrong++">Wait</button>
            <a class="ytp-skip-ad-button" onclick="wrong++">Shop now</a>
            <button class="ytp-skip-ad-button-modern" onclick="skips++">Skip</button></div>
            <script>window.skips=0;window.wrong=0;window.playingAd=false;
            navigator.mediaSession.metadata=new MediaMetadata({title:'Sponsor slogan'});
            Object.defineProperty(document.querySelector('video'),'paused',{get:()=>!playingAd});
            </script>
            """
        let previous = client.event
        defer { client.event = previous }
        client.event = { method, params in
            guard method == "Fetch.requestPaused", let id = params["requestId"] as? String else {
                previous?(method, params)
                return
            }
            let body = params["resourceType"] as? String == "Document" ? markup : ""
            Task {
                _ = try? await client.call("Fetch.fulfillRequest", ["requestId": id, "responseCode": 200,
                    "responseHeaders": [["name":"Content-Type","value":"text/html; charset=utf-8"]],
                    "body": Data(body.utf8).base64EncodedString()])
            }
        }
        _ = try await client.call("Fetch.enable", ["patterns": [["urlPattern": "*"]]])
        try await page.navigate("https://www.youtube.com/watch?v=orvlet-fixture")
        var checks: [String] = []
        func expect(_ expression: String, _ label: String) async throws {
            for _ in 0..<50 {
                if (try? await page.evaluate(expression)) as? Bool == true {
                    try StateMachineCheck.require(true, label, &checks)
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppError.message(label)
        }
        try await expect("window.__orvlet?.state().adPlaying && window.__orvlet.state().title==='Chillhop Café' && skips===0",
            "Native Chromium recognizes a paused YouTube ad and displays the video's title instead of sponsor metadata")
        model.settings.blockAds = false
        defer { model.settings.blockAds = true }
        try await Task.sleep(for: .milliseconds(1400))
        _ = try await page.evaluate("playingAd=true")
        try await Task.sleep(for: .milliseconds(1400))
        try await expect("skips===0 && wrong===0", "Turning skipping off leaves the playing ad and its links untouched")
        model.settings.blockAds = true
        try await expect("skips>0 && wrong===0", "The native renderer clicks the available Skip button after it is enabled")
        return checks
    }

    private static func checkReminderAudio(_ model: AppModel, page: SystemBrowserPage, owner: UUID) async throws -> [String] {
        var checks: [String] = []
        func waitFor(_ expression: String, _ label: String) async throws {
            let deadline = Date().addingTimeInterval(6)
            repeat {
                if try await page.evaluate(expression) as? Bool == true {
                    try StateMachineCheck.require(true, label, &checks)
                    return
                }
                try await Task.sleep(for: .milliseconds(30))
            } while Date() < deadline
            let state = try? await page.evaluate("JSON.stringify({paused:clip.paused,muted:clip.muted,volume:clip.volume,output:outputVolume(),lowest:lowestOutput})")
            throw AppError.message("\(label) (\(state as? String ?? "unavailable"))")
        }
        func post(_ event: UUID) {
            model.presentCardReminder(owner, eventID: event, message: "Fixture finished",
                                      intensity: .gentle, persistence: .persistent)
        }
        let originalSound = model.settings.alarmSound
        model.settings.alarmSound = .ripples
        // Chromium's native-check process also has --mute-audio. Both output devices stay silent.
        model.playsMutedReminderForCheck = true
        defer {
            model.removeReminders { $0.owner == owner }
            model.stopReminderSound()
            model.playsMutedReminderForCheck = false
            model.settings.alarmSound = originalSound
        }
        _ = try await page.evaluate("""
            window.clip = document.querySelector('audio');
            window.outputVolume = () => Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume').get.call(clip);
            window.lowestOutput = outputVolume();
            clip.addEventListener('volumechange', () => { window.lowestOutput = Math.min(lowestOutput, outputVolume()) });
            clip.loop = true;
            clip.muted = true;
            true
            """)
        let muted = UUID()
        post(muted)
        try await Task.sleep(for: .milliseconds(400))
        try await waitFor("!clip.paused && clip.muted && Math.abs(lowestOutput - 0.37) < 0.01",
                          "A reminder leaves muted playing music and its volume alone")
        model.dismissReminder(muted)
        _ = try await page.evaluate("clip.muted = false; window.startedAt = clip.currentTime; true")
        let first = UUID()
        post(first)
        try await waitFor("!clip.paused && clip.currentTime > startedAt && outputVolume() > 0 && outputVolume() < 0.18 && Math.abs(clip.volume - 0.37) < 0.01",
                          "A persistent cue lowers Chromium's actual output while music advances at the selected volume setting")
        try await model.performMusicControl(owner, operation: "volume", value: 0.63)
        try await waitFor("Math.abs(clip.volume - 0.63) < 0.01 && Math.abs(outputVolume() - 0.063) < 0.005",
                          "Changing the card's volume during cue immediately adjusts the quieter output")
        let replacement = UUID()
        post(replacement)
        guard let ringing = model.activeReminderSounds[.event(.persistent)]?.player else {
            throw AppError.message("The alarm failed to start")
        }
        model.dismissReminder(replacement)
        try StateMachineCheck.require(model.activeReminderSounds[.event(.persistent)]?.eventID == first && ringing.loops,
                                      "Confirming the newest alarm hands the ringing player to the remaining reminder", &checks)
        ringing.currentTime = ringing.duration - 0.25
        try await Task.sleep(for: .milliseconds(900))
        try StateMachineCheck.require(ringing.isPlaying && ringing.currentTime < 2,
                                      "The native alarm loops across the end of the ringtone", &checks)
        try await waitFor("!clip.paused && Math.abs(outputVolume() - 0.063) < 0.005",
                          "Music stays at ten percent between rings until the last alarm is acknowledged")
        model.dismissReminder(first)
        try await waitFor("!clip.paused && !clip.muted && Math.abs(outputVolume() - 0.63) < 0.005",
                          "Confirming the last alarm restores the latest volume without restarting playback")
        let acknowledged = UUID()
        post(acknowledged)
        try await waitFor("outputVolume() < 0.25", "An audible reminder ducks music before acknowledgement")
        model.dismissReminder(acknowledged)
        try await Task.sleep(for: .milliseconds(700))
        try StateMachineCheck.require(try await page.evaluate("!clip.paused && Math.abs(outputVolume() - 0.63) < 0.005") as? Bool == true,
                                      "Acknowledging mid-phrase releases music before the chime would have finished", &checks)
        model.settings.alarmSound = .slowRise
        let longAlarm = UUID()
        model.presentCardReminder(owner, eventID: longAlarm, message: "Timer finished", intensity: .strong, persistence: .persistent)
        guard let phrase = model.activeReminderSounds[.event(.persistent)]?.player else {
            throw AppError.message("The long alarm failed to start")
        }
        let message = UUID()
        model.presentCardReminder(owner, eventID: message, message: "Saved", persistence: .brief)
        try await Task.sleep(for: .milliseconds(3300))
        try StateMachineCheck.require(phrase.isPlaying && phrase.currentTime > 3 && model.activeReminderSounds[.event(.brief)] == nil,
                                      "A short message finishes independently and the strongest repeat lets Slow Rise play past three seconds", &checks)
        try await waitFor("outputVolume() < 0.25", "Music stays ducked until the remaining alarm is acknowledged")
        model.dismissReminder(message)
        model.dismissReminder(longAlarm)
        try await waitFor("Math.abs(outputVolume() - 0.63) < 0.005", "Acknowledging the long alarm restores the selected music volume")
        model.settings.alarmSound = .silent
        _ = try await page.evaluate("window.lowestOutput = outputVolume(); true")
        let silent = UUID()
        post(silent)
        try await Task.sleep(for: .milliseconds(500))
        try await waitFor("!clip.paused && Math.abs(lowestOutput - 0.63) < 0.005",
                          "A silent reminder leaves playing music at full selected volume")
        model.dismissReminder(silent)
        try await model.performMusicControl(owner, operation: "pause")
        model.settings.alarmSound = .ripples
        let paused = UUID()
        post(paused)
        try await Task.sleep(for: .milliseconds(400))
        try await waitFor("clip.paused && !clip.muted && Math.abs(lowestOutput - 0.63) < 0.005",
                          "A cue leaves paused music paused at its last volume")
        model.dismissReminder(paused)
        return checks
    }

    /// AppKit's cache excludes accelerated Chromium layers. Compose the actual
    /// shell capture with the actual compositor capture at its measured NSView
    /// bounds; this is a QA artifact, never the application's presentation path.
    private static func snapshot(_ window: NSWindow, browser: BrowserController, path: String) async throws {
        guard let content = window.contentView, let native = browser.systemPage?.nativeBrowser,
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds),
            let bytes = Data(base64Encoded: try await browser.screenshot()), let page = NSImage(data: bytes) else {
            throw AppError.message("Could not capture the native shell")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        var rectangle = native.view.convert(native.view.bounds, to: content)
        if content.isFlipped { rectangle.origin.y = content.bounds.height - rectangle.maxY }
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rectangle, xRadius: 10, yRadius: 10).addClip()
        page.draw(in: rectangle, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let result = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try result.write(to: URL(fileURLWithPath: path))
    }
}
#endif
