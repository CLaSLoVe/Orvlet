import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func didOpenExternally(_ url: URL, source: WindowPlayer) async {
        guard visibleWindowPlayer === source, source.address == url else { return }
        let controller = visibleSourceBrowser
        let owner = liveBrowsers.first { $0.id == playbackCoordinator.owner }
        let state = await source.mediaState()
        guard visibleWindowPlayer === source, source.address == url else { return }
        if state == .playing { controller?.setUserPlaybackPaused(true, origin: "external_open") }
        editingWebAddress = false
        onParkCapsule?()
        collapse(keepingSource: true)
        if state == .playing {
            if let controller { await controller.applyPlaybackPolicy() }
            else { await source.web?.pauseAllMediaPlayback() }
        }
        if state != .none, let owner, owner !== controller, playbackCoordinator.owner == owner.id {
            let generation = owner.playbackGeneration
            if await owner.windowPlayer.mediaState() == .playing, owner.playbackGeneration == generation,
               playbackCoordinator.owner == owner.id, !owner.disposed {
                owner.setUserPlaybackPaused(true, origin: "external_open")
                await owner.applyPlaybackPolicy()
            }
        }
    }

    func requestAddress() {
        if showingWeb && !taskShelfVisible && visibleHandoff?.document == nil && visibleHandoff?.isBrowserManager != true {
            if sourceIsFullscreen { activeWindowPlayer?.exit() }
            editingWebAddress = true
            addressFocusRequest += 1
            return
        }
        let prompt = NSAlert()
        prompt.messageText = "Open web address"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Enter web address"
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Open")
        prompt.addButton(withTitle: "Cancel")
        prompt.window.initialFirstResponder = field
        while prompt.runModal() == .alertFirstButtonReturn {
            if let url = Self.addressURL(field.stringValue) {
                openURL(url.absoluteString)
                onShow?()
                return
            }
            prompt.informativeText = "Enter a valid web address."
        }
    }
    func navigateHistory(_ action: String) {
        controlInteraction(true)
        Task {
            defer { controlInteraction(false) }
            do { _ = try await performBrowserAction(["action": action]) } catch {
                webError = error.localizedDescription
            }
        }
    }
    static func externalPageURL(_ url: URL?) -> URL? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func addressURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let value = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }
    func didEnterWebAddress(_ destination: URL, replacing previous: URL?, taskID: UUID) {
        guard let previous,
            SurfaceCache.pageKey(previous.absoluteString) != SurfaceCache.pageKey(destination.absoluteString),
            let index = sideTasks.firstIndex(where: { $0.id == taskID }),
            sideTasks[index].musicSessionRole != nil || sideTasks[index].musicQueue != nil else { return }
        if let track = MusicTrack.videoID(previous.absoluteString), MusicTrack.videoID(destination.absoluteString) == track { return }
        // The person repurposed this page. Old queue events and a later song request
        // must not navigate it back to its former track.
        if let run = runOwning(taskID), run.context?.musicSessionRole != nil {
            run.context?.expectsPlayback = false
            run.context?.musicSessionRole = nil
            stopCommand(for: taskID)
        }
        musicJobs.removeValue(forKey: taskID)?.cancel()
        musicRevisions[taskID] = nil
        musicLoading.remove(taskID)
        musicErrors[taskID] = nil
        musicQueueExpanded.remove(taskID)
        sideTasks[index].musicSessionRole = nil
        sideTasks[index].musicQueue = nil
        sideTasks[index].listening = false
        sideTasks[index].prefersSource = true
        if preferredMediaTaskID == taskID { preferredMediaTaskID = nil }
        if browser.id == taskID { endBackgroundListening() }
        persistSideTasks()
    }
    func openURL(_ raw: String, background: Bool = false) {
        guard let url = Self.addressURL(raw) else {
            webError = "Enter a valid web address."
            return
        }
        do { try prepareBrowserForNewTask(destination: url.absoluteString) } catch {
            webError = error.localizedDescription
            return
        }
        saveSession(force: true)
        endBackgroundListening()
        webError = nil
        hasCustomSurface = false
        taskFailed = false
        latestIntent = raw
        surface = .webpage
        collapsed = background
        webExpanded = !background
        onResize?(windowSize)
        if externalBrowser && browserConnected {
            Task {
                do { _ = try await bridge.externalAction(["action": "navigate", "url": url.absoluteString]) } catch {
                    webError = error.localizedDescription
                }
            }
        } else {
            Task {
                do { _ = try await performBrowserAction(["action": "navigate", "url": url.absoluteString]) } catch {
                    webError = error.localizedDescription
                }
            }
        }
    }
    func perform(_ binding: PageBinding, text: String? = nil, value: Double? = nil, then submit: PageBinding? = nil) {
        if binding.action == "media", let operation = binding.operation,
            ["play", "pause", "toggle", "next"].contains(operation)
        {
            controlMedia(browser.id, operation: operation)
            return
        }
        if restoringSession {
            queuedRestoreAction = { [weak self] in self?.perform(binding, text: text, value: value, then: submit) }
            return
        }
        lastActionError = nil
        controlInteraction(true)
        let target = browser
        let useExternal = externalBrowser && browserConnected
        Task {
            defer { controlInteraction(false) }
            do {
                var input = binding.dictionary
                if let text { input["text"] = text }
                if let value { input["value"] = value }
                if useExternal {
                    guard browser.id == target.id else { throw CancellationError() }
                    _ = try await bridge.externalAction(input)
                    if let submit {
                        guard browser.id == target.id else { throw CancellationError() }
                        _ = try await bridge.externalAction(submit.dictionary)
                    }
                } else {
                    _ = try await target.action(input)
                    if let submit { _ = try await target.action(submit.dictionary) }
                }
                if browser.id == target.id { lastInteraction = binding.operation ?? binding.action }
            } catch is CancellationError {} catch {
                if browser.id == target.id {
                    reportTaskIssue(target.id, source: .interface,
                                    detail: "The page control changed. Reconnecting it; your action has not been completed.")
                    lastActionError = "Page changed. Reconnecting controls…"
                    adaptive.bindingFailed()
                } else {
                    reportTaskIssue(target.id, source: .interface, detail: "The page control changed. Reopen the task and try the action again.",
                                    requiresAttention: true)
                }
            }
        }
    }
}
