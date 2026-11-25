#if DEBUG
import AppKit
import SwiftUI
import WebKit

@MainActor
enum DetailViewportCheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        let suite = "orvlet-detail-viewport-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["width": 480, "height": 300], forKey: "webWindowSize")
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.reduceMotion = true
        model.settings.compactLayout = .vertical
        model.settings.appearance = .light
        let browser = model.browser
        browser.webView.loadHTMLString("<html><body style='font:16px system-ui;padding:16px'><title>Reading list</title><h2>Reading list</h2><p>An item from the original page.</p></body></html>", baseURL: URL(string: "http://127.0.0.1:19244/reading?list=1#saved"))
        try await Task.sleep(for: .milliseconds(300))
        var task = SideTask(id: browser.id, kind: .web, title: "Reading list")
        var plan = SurfacePlan.webpage
        plan.markup = CardMarkup(html: "<h2>Reading list</h2><p>Saved for later</p>", compactHTML: "Reading list", css: "h2{font-size:18px}", height: 100)
        task.sourceURL = browser.webView.url?.absoluteString
        task.plan = plan
        model.surface = plan
        task.prefersSource = false
        task.mediaPrimary = false
        model.sideTasks = [task]
        model.selectedTaskID = task.id
        model.hasCustomSurface = true
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = NSRect(x: -16000, y: -16000, width: 1200, height: 900)
        let anchor = NSRect(x: screen.maxX - 380, y: screen.maxY - 180,
                            width: model.compactSize.width, height: model.compactSize.height)
        let delegate = AppDelegate(model: model)
        let panel = ShellPanel(contentRect: anchor, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        delegate.panel = panel
        panel.delegate = delegate
        defer {
            model.onResize = nil
            panel.orderOut(nil)
            model.handoffSource?.close()
            browser.dispose()
            model.taskRuntime.stopAll()
        }
        model.onParkCapsule = { [weak delegate] in delegate?.parkCapsuleInCorner(in: screen) }
        model.onResize = { [weak delegate] size in delegate?.resize(to: size, in: screen) }
        delegate.resize(to: model.windowSize, in: screen)
        var externalOpen: URL?
        let hosting = NSHostingView(rootView: ContentView(model: model).environment(\.openURL, OpenURLAction { url in
            externalOpen = url
            return .handled
        }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderBack(nil)
        func check(_ passed: Bool, _ label: String) throws {
            try StateMachineCheck.require(passed, label, &checks)
        }
        model.selectTask(task.id, expanded: true, preferSource: false)
        try await Task.sleep(for: .milliseconds(350))
        panel.contentView?.layoutSubtreeIfNeeded()
        let card = panel.frame
        try check(model.shellLayout.content.size == model.cardWindowSize(model.selectedSideTask) && !panel.styleMask.contains(.resizable),
                  "The rendered card uses its designed size")
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-stable-card.png")
        model.openTaskFromDoubleClick(task.id)
        try check(model.showingWeb && model.shellLayout.content.size == NSSize(width: 480, height: 300)
                  && panel.styleMask.contains(.resizable), "Double-click opens a resizable source at its saved size")
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let readingPage = browser.webView
        let displayedWidth = hosting.convert(readingPage.bounds, from: readingPage).width
        let cssWidth = try await readingPage.evaluateJavaScript("innerWidth") as? Double ?? 0
        try check(displayedWidth > 400 && displayedWidth <= 480 && abs(cssWidth - displayedWidth) < 1,
                  "Narrow reading pages lay out at the displayed width, with one CSS pixel per window point")
        let newSize = NSSize(width: 950, height: 660)
        let resized = ShellLayout.place(anchor: anchor, content: newSize, orientation: .vertical, screen: screen)
        delegate.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
        panel.setFrame(resized.frame, display: true)
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        try check(model.preferredWebSize == newSize, "A native resize remembers just the source dimensions")
        try await Task.sleep(for: .milliseconds(150))
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-stable-source.png")
        model.settings.reduceMotion = false
        model.selectTask(task.id, expanded: true, preferSource: false)
        if !model.motionReduced {
            try await Task.sleep(for: .milliseconds(100))
            let middle = panel.frame
            try check(middle.width > card.width && middle.width < resized.frame.width &&
                      middle.maxX < resized.frame.maxX && middle.maxX > card.maxX,
                      "The window shrinks and slides back together through an intermediate frame")
            model.openTaskFromDoubleClick(task.id)
            try check(panel.frame == middle, "Reversing a transition starts at the displayed frame")
            try await Task.sleep(for: .milliseconds(450))
            try check(panel.frame == resized.frame, "Rapid reversal lands at the resized webpage")
            model.selectTask(task.id, expanded: true, preferSource: false)
        }
        try await Task.sleep(for: .milliseconds(450))
        try check(panel.frame == card && !panel.styleMask.contains(.resizable), "The card returns to its original frame and corner")
        model.collapse()
        try await Task.sleep(for: .milliseconds(400))
        try check(panel.frame == anchor, "Collapsing returns to the parked strip")
        model.settings.reduceMotion = true
        model.openTaskFromDoubleClick(task.id)
        try check(panel.frame == resized.frame, "Reopening the source restores the saved web viewport")
        var small = SideTask(kind: .result, title: "Local note")
        small.markup = CardMarkup(html: "<p>Local note</p>", compactHTML: "Note", css: "", height: 100)
        model.sideTasks.append(small)
        model.selectTask(small.id, expanded: true, preferSource: false)
        let smallSize = model.windowSize
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-viewport-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Original local note".utf8).write(to: file)
        model.openHandoff(file, taskID: small.id)
        try check(model.visibleHandoff != nil && model.windowSize == newSize, "Original files use the remembered source viewport")
        model.selectTask(small.id, expanded: true, preferSource: false)
        try check(model.windowSize == smallSize && smallSize.width == 328, "A short card retains its own dimensions")
        for orientation in [CompactLayout.vertical, .horizontal] {
            for right in [false, true] {
                for top in [false, true] {
                    let dock = NSRect(x: right ? screen.maxX - 158 : screen.minX + 22,
                                      y: top ? screen.maxY - 112 : screen.minY + 22, width: 136, height: 90)
                    let placed = ShellLayout.place(anchor: dock, content: newSize, orientation: orientation, screen: screen)
                    try check((right ? placed.frame.maxX == dock.maxX : placed.frame.minX == dock.minX)
                              && (top ? placed.frame.maxY == dock.maxY : placed.frame.minY == dock.minY)
                              && placed.resized(to: placed.frame) == placed && screen.contains(placed.frame),
                              "Source expands inward at dock corner right=\(right) top=\(top), \(orientation)")
                }
            }
        }
        model.pointerChanged(true)
        let expanded = model.shellLayout
        let beforePin = expanded.content
        model.pinned = true
        try check(panel.frame.maxX == anchor.maxX && panel.frame.maxX < screen.maxX && panel.frame.maxY == beforePin.maxY
                  && panel.frame == model.shellLayout.content && panel.frame.size == beforePin.size,
                  "Pin aligns the detail to the original capsule right edge inside the display")
        let midpoint = model.shellLayout.transitioning(from: expanded, progress: 0.5)
        try check(midpoint.presentedCompact.width > 0 && midpoint.presentedCompact.width < expanded.compact.width,
                  "The capsule retracts progressively during pinning")
        panel.onMoveInteraction = { [weak delegate] in delegate?.windowMoveChanged($0) }
        for point in [NSPoint(x: screen.minX + 20, y: screen.minY + 60),
                      NSPoint(x: screen.maxX - beforePin.width, y: screen.maxY - beforePin.height - 60)] {
            panel.moveInteraction(true)
            panel.setFrameOrigin(point)
            panel.moveInteraction(false)
            model.pointerChanged(false)
            try check(panel.frame.origin == point && panel.frame == model.shellLayout.content
                      && !model.detailControlsVisible, "A deliberate drop survives auto-hide")
            model.pointerChanged(true)
            try check(panel.frame.origin == point && model.detailControlsVisible,
                      "Revealing pinned controls keeps the drop position")
        }
        func clickPinnedTasks(y: CGFloat) throws {
            hosting.layoutSubtreeIfNeeded()
            let point = NSPoint(x: hosting.bounds.maxX - 22, y: hosting.isFlipped ? y : hosting.bounds.height - y)
            guard let button = hosting.hitTest(hosting.convert(point, to: hosting.superview)) as? WindowDragArea.DragView,
                  let click = button.onClick else { throw AppError.message("Pinned tasks button is unreachable") }
            click()
        }
        try await Task.sleep(for: .milliseconds(100))
        try clickPinnedTasks(y: 15)
        try check(model.taskShelfVisible && panel.frame.maxX == screen.maxX, "The right-hand task button opens the docked shelf")
        try await Task.sleep(for: .milliseconds(100))
        try clickPinnedTasks(y: 26)
        try check(!model.taskShelfVisible && panel.frame.maxX == screen.maxX, "The shelf returns directly to the pinned card")

        model.openTaskFromDoubleClick(task.id)
        try await Task.sleep(for: .milliseconds(200))
        let sourceWindow = panel.frame
        let web = browser.webView
        func webRect() -> NSRect { hosting.convert(web.bounds, from: web) }
        let fullscreenAvailable = try await web.evaluateJavaScript(
            "document.fullscreenEnabled && typeof document.createElement('video').requestFullscreen === 'function'") as? Bool
        try check(fullscreenAvailable == true, "The embedded player exposes window-local fullscreen")
        model.trackSourcePointer(y: 3)
        try await Task.sleep(for: .milliseconds(80))
        let withControls = webRect()
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-docked-source-hover.png")
        model.settings.reduceMotion = false
        model.pointerChanged(false)
        if !model.motionReduced {
            try await Task.sleep(for: .milliseconds(80))
            try check(webRect() == withControls,
                      "The live page stays still while the floating toolbar retracts")
            model.pointerChanged(true)
            model.trackSourcePointer(y: 3)
            try await Task.sleep(for: .milliseconds(65))
            model.pointerChanged(false)
        }
        try await Task.sleep(for: .milliseconds(350))
        let withoutControls = webRect()
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-docked-source-hidden.png")
        try check(web.window === panel && panel.frame == sourceWindow && panel.frame.maxX == screen.maxX
                  && withoutControls == withControls
                  && abs(withoutControls.width - hosting.bounds.width) < 1
                  && abs(withoutControls.height - hosting.bounds.height) < 1,
                  "The live webpage fills the pinned window throughout toolbar reveal and dismissal")
        let topPoint = NSPoint(x: hosting.bounds.midX, y: hosting.isFlipped ? 14 : hosting.bounds.height - 14)
        let hit = hosting.hitTest(hosting.convert(topPoint, to: hosting.superview))
        let pageText = try await web.evaluateJavaScript("document.body.innerText") as? String
        try check(hit?.isDescendant(of: web) == true && pageText?.contains("An item from the original page.") == true,
                  "The exposed top of the window accepts input in the original live page")
        let pageImage = try await web.takeSnapshot(configuration: nil)
        if let data = pageImage.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/orvlet-docked-web-content.png"))
        }
        model.pointerChanged(true)
        model.trackSourcePointer(y: 3)
        try await Task.sleep(for: .milliseconds(350))
        try check(web.window === panel && webRect() == withControls && panel.frame == sourceWindow,
                  "Re-entry restores both toolbars without moving the window or remounting its source")

        model.settings.reduceMotion = true
        let sourceID = model.selectedTaskID
        _ = try await web.evaluateJavaScript("""
            let player = document.createElement('section');
            player.innerHTML = '<video playsinline style="width:180px;height:100px"></video><button style="position:absolute;bottom:12px;right:12px">Subtitles</button>';
            player.style.cssText = 'width: 240px; height: 120px; background: navy; color: white';
            document.body.append(player);
            window.originalPlayer = player; window.originalVideo = player.firstChild; true;
            """)
        let entered = try await web.callAsyncJavaScript("await originalPlayer.requestFullscreen(); return document.fullscreenElement === originalPlayer",
                                                        arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(150))
        let fills = try await web.evaluateJavaScript("""
            (()=>{const r=originalPlayer.getBoundingClientRect();return r.left===0 && r.top===0 &&
            Math.abs(r.width-innerWidth)<1 && Math.abs(r.height-innerHeight)<1 && originalVideo===originalPlayer.firstChild &&
            Math.abs(originalVideo.offsetWidth-innerWidth)<1 && Math.abs(originalVideo.offsetHeight-innerHeight)<1 &&
            document.elementFromPoint(innerWidth-25,innerHeight-20)===originalPlayer.lastChild})()
            """)
        try check(entered as? Bool == true && fills as? Bool == true && model.sourceIsFullscreen
                  && web.fullscreenState == .notInFullscreen && web.window === panel && panel.frame == sourceWindow
                  && abs(webRect().height-panel.frame.height)<1,
                  "The original player and controls fill the existing Orvlet window without system fullscreen")
        model.trackSourcePointer(y: 100)
        try await Task.sleep(for: .milliseconds(1500))
        let exitPoint = NSPoint(x: hosting.bounds.midX, y: hosting.isFlipped ? 20 : hosting.bounds.height - 20)
        func exitHit() -> NSView? { hosting.hitTest(hosting.convert(exitPoint, to: hosting.superview)) }
        try check(exitHit()?.isDescendant(of: web) == true, "The fullscreen exit hint yields clicks back to the player")
        model.trackSourcePointer(y: 3)
        try await Task.sleep(for: .milliseconds(100))
        guard let exitButton = exitHit() as? WindowDragArea.DragView, let clickExit = exitButton.onClick else {
            throw AppError.message("The fullscreen exit button is unreachable")
        }
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-fullscreen-exit.png")
        clickExit()
        try await Task.sleep(for: .milliseconds(120))
        let restoredPlayer = try await web.evaluateJavaScript("""
            !document.fullscreenElement && originalPlayer.getBoundingClientRect().width===240 &&
                originalPlayer.firstChild===originalVideo && originalVideo.offsetWidth===180 && !originalPlayer.hasAttribute('popover')
            """)
        try check(restoredPlayer as? Bool == true && !model.sourceIsFullscreen && webRect() == withControls,
                  "Exiting restores the same video, page layout and toolbar")
        // A separate, sandboxed origin exercises the frame-to-frame handshake.
        let frameProbe = EmbeddedFrameProbe()
        let messages = web.configuration.userContentController
        messages.add(frameProbe, name: "orvletTestFrame")
        defer { messages.removeScriptMessageHandler(forName: "orvletTestFrame") }
        _ = try await web.evaluateJavaScript("""
            let embed = document.createElement('iframe');
            embed.allowFullscreen = true;
            embed.setAttribute('sandbox', 'allow-scripts');
            embed.srcdoc = '<section id="movie" style="width:160px"><video playsinline></video><button>Controls</button></section><script>webkit.messageHandlers.orvletTestFrame.postMessage(true)<'+ '/script>';
            document.body.append(embed); true;
            """)
        for _ in 0..<40 where frameProbe.frame == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard let child = frameProbe.frame else { throw AppError.message("Embedded player fixture did not load") }
        let childEntered = try await web.callAsyncJavaScript(
            "await movie.requestFullscreen(); return document.fullscreenElement === movie && Math.abs(movie.getBoundingClientRect().width-innerWidth)<1",
            arguments: [:], in: child, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(150))
        let frameFills = try await web.evaluateJavaScript(
            "document.fullscreenElement===embed && Math.abs(embed.getBoundingClientRect().width-innerWidth)<1")
        try check(childEntered as? Bool == true && frameFills as? Bool == true && model.sourceIsFullscreen
                  && web.window === panel && panel.frame == sourceWindow,
                  "A permitted cross-origin embedded player fills both its frame and the Orvlet window")
        model.requestAddress()
        try await Task.sleep(for: .milliseconds(180))
        try check(!model.sourceIsFullscreen && model.editingWebAddress && panel.firstResponder is NSTextView,
                  "Command-L exits the fullscreen player and focuses its existing address field")
        panel.makeFirstResponder(nil)
        let childExited = try await web.callAsyncJavaScript("return !document.fullscreenElement && movie.offsetWidth===160",
                                                            arguments: [:], in: child, contentWorld: .page)
        try check(childExited as? Bool == true && !model.sourceIsFullscreen,
                  "Leaving fullscreen restores the embedded player inside the original page")
        let beforeURL = web.url
        browser.setUserPlaybackPaused(false)
        await browser.applyPlaybackPolicy()
        _ = try await web.callAsyncJavaScript("""
            const clip = movie.querySelector('video');
            clip.muted = true; clip.loop = true; clip.src = 'http://127.0.0.1:19244/tone.wav';
            await clip.play(); return true;
            """, arguments: [:], in: child, contentWorld: .page)
        var embeddedState = await browser.windowPlayer.mediaState()
        for _ in 0..<20 where embeddedState != .playing {
            try await Task.sleep(for: .milliseconds(40))
            embeddedState = await browser.windowPlayer.mediaState()
        }
        try check(embeddedState == .playing, "Playback inside an embedded frame belongs to the open source")
        let playing = try await web.callAsyncJavaScript("""
            window.track = document.createElement('audio');
            track.muted = true; track.loop = true; track.src = '/tone.wav'; document.body.append(track);
            await track.play(); return !track.paused;
            """, arguments: [:], in: nil, contentWorld: .page)
        try check(playing as? Bool == true, "A silent local playback fixture is running before handoff")
        func openExternally() throws {
            let point = NSPoint(x: hosting.bounds.maxX - 22, y: hosting.isFlipped ? 41 : hosting.bounds.height - 41)
            guard let button = hosting.hitTest(hosting.convert(point, to: hosting.superview)) as? WindowDragArea.DragView,
                  let open = button.onClick else { throw AppError.message("The external browser button is unreachable") }
            open()
        }
        try openExternally()
        for _ in 0..<50 where !model.collapsed || !browser.userPausedPlayback { try await Task.sleep(for: .milliseconds(50)) }
        let paused = try await web.evaluateJavaScript("track.paused && originalPlayer.firstChild === originalVideo")
        let safe = screen.insetBy(dx: 8, dy: 8)
        let inCorner = (panel.frame.maxX == safe.maxX || panel.frame.minX == safe.minX)
                    && (panel.frame.maxY == safe.maxY || panel.frame.minY == safe.minY)
        try check(externalOpen == beforeURL && externalOpen?.fragment == "saved" && web.url == beforeURL
                  && model.selectedTaskID == sourceID && model.collapsed && !model.pinned && inCorner
                  && panel.frame.size == model.compactSize && paused as? Bool == true && browser.userPausedPlayback,
                  "Opening externally preserves the URL and live document, pauses playback and parks the unpinned capsule in a corner")
        model.openTaskFromDoubleClick(task.id)
        model.pinned = true
        model.pointerChanged(true)
        model.trackSourcePointer(y: 3)
        try await Task.sleep(for: .milliseconds(180))
        let sameDocument = try await web.evaluateJavaScript("track.paused && originalPlayer.firstChild === originalVideo")
        try check(web.window === panel && sameDocument as? Bool == true, "Reopening the capsule restores the same paused page")
        let addressPoint = NSPoint(x: hosting.bounds.midX, y: hosting.isFlipped ? 41 : hosting.bounds.height - 41)
        let addressHit = hosting.hitTest(hosting.convert(addressPoint, to: hosting.superview))
        let addressField = addressHit.flatMap { hit in sequence(first: hit, next: { $0.superview }).lazy.compactMap { $0 as? NSTextField }.first }
        guard let addressField else { throw AppError.message("Address field did not receive the toolbar hit: \(String(describing: addressHit))") }
        let nextAddress = "http://127.0.0.1:19244/qualifier?city=Beijing"
        panel.makeFirstResponder(addressField)
        guard let editor = addressField.currentEditor() as? NSTextView else { throw AppError.message("Address field could not begin editing") }
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        model.requestAddress()
        for _ in 0..<40 where editor.selectedRange().length != editor.string.utf16.count {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count) && !editor.string.isEmpty,
                  "Command-L selects the entire address again inside an active editor")
        editor.insertText(nextAddress, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        for _ in 0..<60 where web.url?.absoluteString != nextAddress { try await Task.sleep(for: .milliseconds(50)) }
        try check(web.url?.absoluteString == nextAddress && model.selectedTaskID == sourceID && web.window === panel,
                  "Submitting the visible address field loads the address in the same task window")
        // The address bar can open an article while another Orvlet task is playing.
        for _ in 0..<60 where browser.loading { try await Task.sleep(for: .milliseconds(50)) }
        let background = BrowserController(model: model)
        model.parkedBrowsers[background.id] = background
        defer { model.parkedBrowsers.removeValue(forKey: background.id); background.dispose() }
        background.webView.loadHTMLString("<audio muted loop id='music' src='/tone.wav'></audio>",
                                          baseURL: URL(string: "http://127.0.0.1:19244/background-music"))
        for _ in 0..<60 {
            if (try? await background.webView.evaluateJavaScript("document.querySelector('audio')?.readyState >= 2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        background.setUserPlaybackPaused(false)
        await background.applyPlaybackPolicy()
        _ = try await background.webView.callAsyncJavaScript("music.muted=true; await music.play(); return true",
                                                             arguments: [:], in: nil, contentWorld: .page)
        let clipIsIdle = try await web.callAsyncJavaScript("""
            document.body.innerHTML = '<article><h1>Reading list</h1><p>Further reading</p></article>';
            const clip = document.createElement('video');
            clip.controls = true; clip.muted = true; clip.preload = 'auto';
            clip.style.cssText = 'position:absolute;top:4000px;width:80px;height:45px';
            const loaded = new Promise((resolve, reject) => {
                clip.onloadedmetadata = resolve; clip.onerror = () => reject(new Error('Article clip failed to load'));
            });
            clip.src = '/tone.wav'; document.body.append(clip); await loaded;
            return clip.played.length === 0 && clip.getBoundingClientRect().top > innerHeight;
            """, arguments: [:], in: nil, contentWorld: .page)
        try check(clipIsIdle as? Bool == true, "The article contains a loaded, never-played clip below the fold")
        guard let articleURL = web.url else { throw AppError.message("The article URL is missing") }
        let articleState = await browser.windowPlayer.mediaState()
        try check(articleState == .none, "The source page distinguishes its idle clip from another task's playing audio")
        await model.didOpenExternally(articleURL, source: browser.windowPlayer)
        let musicContinues = try await background.webView.evaluateJavaScript("!music.paused")
        try check(model.collapsed && musicContinues as? Bool == true && !background.userPausedPlayback,
                  "Opening an article with an offscreen clip keeps the other task playing")
        model.openTaskFromDoubleClick(task.id)
        model.pinned = true
        model.pointerChanged(true)
        model.trackSourcePointer(y: 3)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await web.evaluateJavaScript("""
            (() => {
                const player = document.querySelector('video');
                document.body.replaceChildren(player);
                player.style.cssText = 'width:85vw;height:75vh'; return true;
            })()
            """)
        try openExternally()
        for _ in 0..<60 where !background.userPausedPlayback { try await Task.sleep(for: .milliseconds(50)) }
        let musicPaused = try await background.webView.evaluateJavaScript("music.paused")
        try check(model.collapsed && background.userPausedPlayback && musicPaused as? Bool == true,
                  "Opening a playback page externally pauses the currently playing Orvlet task")
        let first = UUID(), second = UUID()
        model.deliverReply("   ", taskID: first)
        try check(!model.hasUnreadReply, "An empty reply never lights the composer badge")
        model.deliverReply("Your note is ready.", taskID: first)
        model.deliverReply("Your timer is ready.", taskID: second)
        model.collapse()
        model.dismissFeedback()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let plus = NSPoint(x: hosting.bounds.width - 22, y: hosting.isFlipped ? 20 : hosting.bounds.height - 20)
        guard let button = hosting.hitTest(hosting.convert(plus, to: hosting.superview)) as? WindowDragArea.DragView,
              button.onClick != nil else { throw AppError.message("The compact plus button is unreachable") }
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-plus-unread.png")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: hosting.convert(plus, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { button.mouseDown(with: event) } else { button.mouseUp(with: event) }
        }
        try check(model.conversationTaskID == second && model.visibleConversation.last?.text == "Your timer is ready."
                  && model.latestUnreadReply?.taskID == first, "The badge opens its reply and preserves other unread replies")
        model.openComposerOrUnreadReply()
        try check(!model.hasUnreadReply && model.visibleConversation.last?.text == "Your note is ready.",
                  "Reading the last reply clears the badge")
        model.selectChat(false)
        try await Task.sleep(for: .milliseconds(100))
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-plus-read.png")
        model.reportTaskIssue(task.id, source: .browser, detail: "Unavailable")
        model.resolveTaskIssue(task.id, source: .browser)
        try check(!model.hasUnreadReply, "A resolved issue leaves no stale dot")
        model.deliverReply("Temporary reply", taskID: second)
        model.messages.removeAll { $0.taskID == second }
        model.openComposerOrUnreadReply()
        try check(!model.hasUnreadReply && model.conversationTaskID == nil && !model.conversationHistoryVisible,
                  "Deleting the unread message restores the ordinary new-task composer")
        panel.orderOut(nil)
        try StateMachineCheck.require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !panel.isVisible,
            "Card/source frame checks run offscreen without changing desktop focus", &checks)
        return checks
    }
}
@MainActor
private final class EmbeddedFrameProbe: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if !message.frameInfo.isMainFrame { frame = message.frameInfo }
    }
}
#endif
