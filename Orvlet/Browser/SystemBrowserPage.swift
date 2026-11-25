import AppKit
import Combine

/// One real Chromium page per task. Frames are live; input goes to that same renderer.
@MainActor
final class SystemBrowserPage: ObservableObject {
    let host: SystemBrowserHost
    weak var owner: BrowserController?
    @Published private(set) var frame: NSImage?
    @Published private(set) var issue: String?
    @Published private(set) var nativeBrowser: NativeBrowser?
    @Published private(set) var currentURL: URL?
    @Published private(set) var historyItems = BrowserHistoryItems()
    private(set) var client: BrowserDevTools?
    private var target: String?
    private var starting: Task<Void, Error>?
    private var polling: Task<Void, Never>?
    private var inputQueue: Task<Void, Never>?
    private var pendingInputs: [BrowserInput] = []
    private var presentationUpdate: Task<Void, Never>?
    private var appliedSize: NSSize?
    private var stopped = false
    private var shown = false
    private var streaming = false
    private var mediaContexts = Set<Int>()
    private var mainFrameID: String?
    private var loader = ""
    private var locationRevision = 0
    private var navigationRevision = 0
    private var gateScript: String?
    private var size = NSSize(width: 1000, height: 700)
    var viewportSize: NSSize { size }
    private var desiredSize = NSSize(width: 1000, height: 700)
    init(host: SystemBrowserHost, owner: BrowserController) { self.host = host; self.owner = owner }

    func ready() async throws {
        guard !stopped else { throw CancellationError() }
        if let starting { return try await starting.value }
        if client?.closed == false, host.isRunning { return }
        client?.close()
        polling?.cancel()
        streaming = false
        appliedSize = nil
        gateScript = nil
        let job = Task { @MainActor [self] in
            if let target { await host.closePage(target); self.target = nil }
            let (id, socket) = try await host.newPage()
            guard !stopped, !Task.isCancelled else { await host.closePage(id); throw CancellationError() }
            target = id
            nativeBrowser = host.nativeBrowser(id)
            let connection = BrowserDevTools(url: socket, session: host.http)
            client = connection
            historyItems = BrowserHistoryItems()
            mediaContexts.removeAll()
            let hostRevision = host.revision
            connection.event = { [weak self, weak connection] method, params in
                guard let self, let connection, client === connection else { return }
                event(method, params)
            }
            connection.failed = { [weak self, weak connection] error in
                guard let self, let connection, client === connection,
                    !stopped, !host.closing, host.revision == hostRevision else { return }
                historyItems = BrowserHistoryItems()
                issue = "The background browser disconnected. Reload to reconnect."
                owner?.windowPlayer.changed(false)
                owner?.systemBrowserFailed(issue!)
                if host.native {
                    disconnectNativePage()
                } else { host.stop() }
                streaming = false
                polling?.cancel()
            }
            _ = try await connection.call("Page.enable")
            _ = try await connection.call("Runtime.enable")
            _ = try await connection.call("Runtime.addBinding", ["name": "__orvletPlaybackRequested", "executionContextName": "orvlet-input"])
            _ = try await connection.call("Page.addScriptToEvaluateOnNewDocument", ["worldName": "orvlet-input", "source": """
                let lastGesture=-Infinity;
                for(const type of ['pointerdown','pointerup','click','keydown']) document.addEventListener(type,e=>{if(e.isTrusted && !e.repeat)lastGesture=performance.now()},true);
                document.addEventListener('orvlet-request-playback',()=>{
                  if(navigator.userActivation?.isActive && performance.now()-lastGesture<1200){lastGesture=-Infinity;window.__orvletPlaybackRequested('play');}
                });
                document.addEventListener('click',e=>{
                  const a=e.target.closest?.('a[target="_blank"]');
                  if(a && /^https?:/.test(a.href) && !e.metaKey && !e.ctrlKey){e.preventDefault();location.href=a.href;}
                },true);
                """])
            _ = try await connection.call("Runtime.addBinding", ["name": "__orvletWindowPlayerChanged", "executionContextName": "orvlet-input"])
            _ = try await connection.call("Page.addScriptToEvaluateOnNewDocument", ["worldName": "orvlet-input", "source": WindowPlayer.observer])
            _ = try await connection.call("Page.addScriptToEvaluateOnNewDocument", ["source": WindowPlayer.script])
            try await updateGate()
            try await resizeNow()
            issue = nil
            polling?.cancel()
            polling = Task { [weak self] in
                while let self, !stopped, !Task.isCancelled {
                    do {
                        if let state = try await evaluate(BrowserController.script + "; window.__orvlet.state()") as? [String: Any],
                            !stopped, owner?.loading == false, state["url"] as? String != "about:blank" { owner?.updateState(state) }
                    } catch {}
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            try await updateStreaming()
        }
        starting = job
        do {
            try await job.value
            starting = nil
            schedulePresentationUpdate()
        } catch {
            starting = nil
            client?.close()
            client = nil
            if let target { await host.closePage(target); self.target = nil }
            nativeBrowser = nil
            throw error
        }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        guard !stopped else { return }
        if method == "Runtime.executionContextCreated", let context = params["context"] as? [String: Any],
           context["name"] as? String == "orvlet-input", let id = context["id"] as? Int {
            mediaContexts.insert(id)
        } else if method == "Runtime.executionContextDestroyed", let id = params["executionContextId"] as? Int {
            mediaContexts.remove(id)
        } else if method == "Runtime.executionContextsCleared" {
            mediaContexts.removeAll()
        } else if method == "Page.screencastFrame" {
            // Always release the producer, even if a frame is hidden or invalid.
            // The acknowledgement belongs to this connection, never a replacement.
            if let id = params["sessionId"] as? Int, let client {
                Task { _ = try? await client.call("Page.screencastFrameAck", ["sessionId": id]) }
            }
            guard shown, let data = params["data"] as? String,
                let bytes = Data(base64Encoded: data), let image = NSImage(data: bytes) else { return }
            frame = image
        } else if method == "Page.frameNavigated", let f = params["frame"] as? [String: Any], f["parentId"] == nil {
            owner?.windowPlayer.changed(false)
            currentURL = (f["url"] as? String).flatMap { URL(string: $0 + (f["urlFragment"] as? String ?? "")) }
            mainFrameID = f["id"] as? String
            loader = f["loaderId"] as? String ?? ""
            didChangeLocation()
        } else if method == "Page.navigatedWithinDocument", let id = params["frameId"] as? String, id == mainFrameID {
            currentURL = (params["url"] as? String).flatMap(URL.init(string:))
            didChangeLocation()
        } else if method == "Runtime.bindingCalled", params["name"] as? String == "__orvletWindowPlayerChanged" {
            owner?.windowPlayer.changed(params["payload"] as? String == "true")
        } else if method == "Runtime.bindingCalled", params["name"] as? String == "__orvletPlaybackRequested" {
            owner?.systemBrowserPlaybackGesture()
        } else if method == "Page.javascriptDialogOpening" {
            // Never allow background dialogs to block the task or appear on the desktop.
            issue = "This page requested a dialog that needs your attention."
            Task { [weak self] in _ = try? await self?.client?.call("Page.handleJavaScriptDialog", ["accept": false]) }
        } else if method == "Inspector.targetCrashed" {
            historyItems = BrowserHistoryItems()
            owner?.windowPlayer.changed(false)
            issue = "The task page stopped. Reload to reconnect."
            owner?.systemBrowserFailed(issue!)
            if host.native { disconnectNativePage() } else { client?.close() }
            streaming = false
        }
    }

    func evaluate(_ script: String, userGesture: Bool = false) async throws -> Any? {
        guard !stopped, let client else { throw CancellationError() }
        let result = try await client.call("Runtime.evaluate", ["expression": script, "returnByValue": true,
            "awaitPromise": true, "userGesture": userGesture])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw AppError.message(exception?["description"] as? String ?? details["text"] as? String ?? "Page action failed.")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    func mediaState() async -> WindowPlayer.MediaState {
        guard let client else { return .none }
        var state = WindowPlayer.MediaState.none
        for id in mediaContexts {
            let response = try? await client.call("Runtime.evaluate", ["contextId": id,
                "expression": WindowPlayer.mediaProbe, "returnByValue": true])
            let value = (response?["result"] as? [String: Any])?["value"] as? Int
            if value == WindowPlayer.MediaState.playing.rawValue { return .playing }
            if value == WindowPlayer.MediaState.primaryPlayer.rawValue { state = .primaryPlayer }
        }
        return state
    }

    func navigate(_ raw: String) async throws {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil else { throw AppError.message("Invalid web address.") }
        navigationRevision += 1
        let revision = navigationRevision
        try await ready()
        try await updateGate()
        guard revision == navigationRevision, !stopped else { throw CancellationError() }
        let result = try await client!.call("Page.navigate", ["url": url.absoluteString])
        if let error = result["errorText"] as? String { throw AppError.message(error) }
        let expected = result["loaderId"] as? String
        for _ in 0..<150 {
            try Task.checkCancellation()
            guard revision == navigationRevision, !stopped else { throw CancellationError() }
            if expected == nil || loader == expected,
                let state = try? await evaluate("document.readyState"), state as? String != "loading" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PageReadUnavailable()
    }

    private func didChangeLocation() {
        locationRevision += 1
        let revision = locationRevision
        guard let client else { return }
        Task { [weak self] in
            guard let items = try? await Self.readHistory(client), let self, self.client === client,
                  !client.closed, locationRevision == revision else { return }
            historyItems = items
        }
    }

    private static func readHistory(_ client: BrowserDevTools) async throws -> BrowserHistoryItems {
        let result = try await client.call("Page.getNavigationHistory")
        guard let entries = result["entries"] as? [[String: Any]], let index = result["currentIndex"] as? Int
        else { return BrowserHistoryItems() }
        func entry(at position: Int) -> Int? {
            guard entries.indices.contains(position) else { return nil }
            let entry = entries[position]
            if position == 0, let url = entry["url"] as? String,
               url == "about:blank" || url.hasPrefix("about:blank#orvlet-") { return nil }
            return entry["id"] as? Int
        }
        return BrowserHistoryItems(back: entry(at: index - 1), forward: entry(at: index + 1))
    }

    func history(_ operation: String, fresh: Bool = false) async throws {
        try await ready()
        navigationRevision += 1
        let revision = navigationRevision
        let before = locationRevision
        if operation == "reload" { _ = try await client!.call("Page.reload", ["ignoreCache": fresh]) }
        else {
            let items = try await Self.readHistory(client!)
            guard revision == navigationRevision, !stopped else { throw CancellationError() }
            guard let id = operation == "back" ? items.back : items.forward else { return }
            _ = try await client!.call("Page.navigateToHistoryEntry", ["entryId": id])
        }
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard revision == navigationRevision, !stopped else { throw CancellationError() }
            if locationRevision != before,
                let state = try? await evaluate("document.readyState"), state as? String != "loading" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PageReadUnavailable()
    }

    func updateGate() async throws {
        guard let client, !stopped else { return }
        let script = BrowserController.playbackGate(held: owner?.playbackSuspended ?? true)
        if let gateScript { _ = try await client.call("Page.removeScriptToEvaluateOnNewDocument", ["identifier": gateScript]) }
        gateScript = try await client.call("Page.addScriptToEvaluateOnNewDocument", ["source": script])["identifier"] as? String
        _ = try await evaluate(script + "; true")
    }

    func screenshot() async throws -> String {
        if client == nil { try await ready() }
        let result = try await client!.call("Page.captureScreenshot", ["format": "jpeg", "quality": 80])
        guard let data = result["data"] as? String else { throw AppError.message("Could not capture the task page.") }
        return data
    }
    func setVisible(_ visible: Bool, size: NSSize) {
        // Hidden/zero-size layout passes must not resize a live background task.
        var wanted = desiredSize
        if visible, size.width >= 1, size.height >= 1 {
            wanted = NSSize(width: size.width.rounded(), height: size.height.rounded())
        }
        guard shown != visible || desiredSize != wanted else { return }
        shown = visible
        desiredSize = wanted
        schedulePresentationUpdate()
    }
    private func schedulePresentationUpdate() {
        guard !stopped, client != nil, starting == nil, presentationUpdate == nil,
            appliedSize != desiredSize || shown != streaming else { return }
        presentationUpdate = Task { [weak self] in
            guard let self else { return }
            defer { presentationUpdate = nil }
            do {
                // Keep only the latest layout; resizing never queues ahead of typing/clicks.
                while !stopped, !Task.isCancelled, appliedSize != desiredSize || shown != streaming {
                    try await resizeNow()
                    try await updateStreaming()
                }
            } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
    private func resizeNow() async throws {
        guard let client, appliedSize != desiredSize else { return }
        let wanted = desiredSize
        if host.native { size = wanted; appliedSize = wanted; return }
        _ = try await client.call("Emulation.setDeviceMetricsOverride", ["width": Int(wanted.width), "height": Int(wanted.height),
            "deviceScaleFactor": 1, "mobile": false])
        guard self.client === client, !stopped else { throw CancellationError() }
        size = wanted
        appliedSize = wanted
    }
    private func updateStreaming() async throws {
        if host.native { streaming = shown; return }
        guard let client, shown != streaming else { return }
        let visible = shown
        if visible {
            // Activate only the tab in Orvlet's windowless private browser. An
            // occluded Chromium tab can otherwise stop producing live frames.
            _ = try await client.call("Page.bringToFront")
            _ = try await client.call("Page.startScreencast", ["format": "jpeg", "quality": 80,
                "maxWidth": 1800, "maxHeight": 1800, "everyNthFrame": 1])
        } else { _ = try await client.call("Page.stopScreencast") }
        guard self.client === client, !stopped else { throw CancellationError() }
        streaming = visible
    }
    func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        pendingInputs.append(.action(action))
        drainInput()
    }
    private func drainInput() {
        guard inputQueue == nil else { return }
        inputQueue = Task { [weak self] in
            guard let self else { return }
            defer { inputQueue = nil }
            while !stopped, !Task.isCancelled, !pendingInputs.isEmpty {
                let next = pendingInputs.removeFirst()
                do {
                    try await ready()
                    switch next {
                    case .command(let method, let params): _ = try await client?.call(method, params)
                    case .action(let action): try await action()
                    }
                } catch is CancellationError {} catch { issue = error.localizedDescription }
            }
        }
    }
    func input(_ method: String, _ params: [String: Any]) {
        guard !stopped else { return }
        let next = BrowserInput.command(method, params)
        if let last = pendingInputs.last, let combined = last.coalescing(next) {
            pendingInputs[pendingInputs.count - 1] = combined
        } else {
            pendingInputs.append(next)
        }
        drainInput()
    }
    func stop() {
        guard !stopped else { return }
        historyItems = BrowserHistoryItems()
        stopped = true
        starting?.cancel()
        polling?.cancel()
        inputQueue?.cancel()
        pendingInputs.removeAll()
        presentationUpdate?.cancel()
        client?.close()
        client = nil
        nativeBrowser = nil
        if let target { self.target = nil; Task { [host] in await host.closePage(target) } }
    }

    /// A failed task must not tear down another task's live native renderer.
    func disconnectNativePage() {
        guard host.native else { return }
        historyItems = BrowserHistoryItems()
        let old = client
        client = nil
        old?.close()
        nativeBrowser = nil
        polling?.cancel()
        streaming = false
        if let target { self.target = nil; Task { [host] in await host.closePage(target) } }
    }
}

struct BrowserHistoryItems: Equatable {
    var back: Int?
    var forward: Int?
}

/// Coalesce only adjacent motion. Press/release, typing, IME and clipboard work
/// are barriers, so a drag or click cannot overtake the input that precedes it.
private enum BrowserInput {
    case command(String, [String: Any])
    case action(@MainActor () async throws -> Void)

    func coalescing(_ next: BrowserInput) -> BrowserInput? {
        guard case .command(let method, let old) = self,
            case .command(let nextMethod, var new) = next,
            method == "Input.dispatchMouseEvent", nextMethod == method,
            let type = old["type"] as? String, type == new["type"] as? String,
            (old["buttons"] as? Int ?? 0) == (new["buttons"] as? Int ?? 0),
            (old["modifiers"] as? Int ?? 0) == (new["modifiers"] as? Int ?? 0)
        else { return nil }
        if type == "mouseMoved" { return next }
        if type == "mouseWheel" {
            // Keep wheel input at its original target; crossing scroll containers
            // must not move one container's accumulated delta into another.
            guard number(old["x"]) == number(new["x"]),
                number(old["y"]) == number(new["y"]) else { return nil }
            for axis in ["deltaX", "deltaY"] {
                let previous = number(old[axis]) ?? 0
                let current = number(new[axis]) ?? 0
                guard previous == 0 || current == 0 || previous.sign == current.sign else { return nil }
                new[axis] = previous + current
            }
            return .command(method, new)
        }
        return nil
    }
    private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}
