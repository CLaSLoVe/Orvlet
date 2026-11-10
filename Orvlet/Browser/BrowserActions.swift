import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func requestAddress() {
        command = selectedSideTask?.sourceURL ?? webURL
        selectChat(true)
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
    static func addressURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let value = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
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
                deliverReply(
                    "The page control changed. Reconnecting it; your action has not been completed.", kind: .failure,
                    taskID: target.id)
                if browser.id == target.id {
                    lastActionError = "Page changed. Reconnecting controls…"
                    adaptive.bindingFailed()
                }
            }
        }
    }
}
