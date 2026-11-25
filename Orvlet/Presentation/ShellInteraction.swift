import SwiftUI
import WebKit

@MainActor
extension AppModel {
    var visibleSourceBrowser: BrowserController? {
        if let handoff = visibleHandoff { return handoff.systemBrowser }
        return liveBrowsers.first { $0.id == selectedSideTask?.id }
    }
    var visibleWindowPlayer: WindowPlayer? {
        guard showingWeb, !taskShelfVisible else { return nil }
        if let source = visibleHandoff { return source.systemBrowser?.windowPlayer ?? source.windowPlayer }
        return visibleSourceBrowser?.windowPlayer
    }
    var sourceIsFullscreen: Bool { activeWindowPlayer != nil && activeWindowPlayer === visibleWindowPlayer }

    func trackSourcePointer(y: CGFloat?) {
        let controlsExposed = pointerNearSourceControls || (!floatingSourceControls && !sourceIsFullscreen)
        let controlsHeight: CGFloat = sourceIsFullscreen ? 46 : 60
        let revealDepth: CGFloat = controlsExposed ? controlsHeight : 8
        let inside = y.map { $0 >= 0 && $0 <= revealDepth } ?? false
        if inside != pointerNearSourceControls { pointerNearSourceControls = inside }
    }

    func pointerChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        refreshStackAttention()
        if !inside { previewHovered = false; trackSourcePointer(y: nil) }
        refreshHover()
    }
    func previewHoverChanged(_ inside: Bool) {
        previewHovered = inside
        refreshHover()
    }
    func controlInteraction(_ active: Bool) {
        activeInteractions = max(0, activeInteractions + (active ? 1 : -1))
        refreshStackAttention()
        refreshHover()
    }
    private var pressedMouseButtons: Int {
        #if DEBUG
            if let pressedMouseButtonsOverride { return pressedMouseButtonsOverride }
        #endif
        return NSEvent.pressedMouseButtons
    }
    func refreshHover() {
        hoverTask?.cancel()
        hoverTask = nil
        guard !taskShelfVisible, !pinned, !chatVisible, !clickExpanded, !editingWebAddress else { return }
        let entering = pointerInside
        if entering {
            guard settings.expandOnHover, previewHovered, collapsed, !webURL.isEmpty, activeInteractions == 0 else {
                return
            }
        } else {
            guard !collapsed else { return }
        }
        hoverTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(entering ? 160 : 260))
                guard let self else { return }
                while !entering && (self.activeInteractions > 0 || self.pressedMouseButtons != 0) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard !self.taskShelfVisible, !self.pinned, !self.chatVisible,
                    !self.editingWebAddress, self.pointerInside == entering
                else { return }
                if entering {
                    guard self.settings.expandOnHover, self.previewHovered, self.activeInteractions == 0,
                        self.pressedMouseButtons == 0
                    else { return }
                    self.reveal(preview: true)
                } else {
                    if !self.sourceIsFullscreen { self.collapse() }
                }
            } catch {}
        }
    }
    func reveal(preview: Bool = false) {
        hoverTask?.cancel()
        clickExpanded = !preview
        collapsed = false
        webExpanded = selectedSideTask?.opensSourceByDefault == true
        onResize?(windowSize)
        onShow?()
    }
    func collapse(keepingSource: Bool = false) {
        if !keepingSource { handoffSource = nil }
        taskShelfVisible = false
        clickExpanded = false
        hoverTask?.cancel()
        collapsed = true
        webExpanded = false
        pinned = false
        onResize?(windowSize)
    }
    func openComposerOrUnreadReply() {
        if let owner = latestUnreadReply?.taskID {
            openTaskConversation(owner)
        } else {
            selectChat(!commandPanelVisible)
        }
    }
    func selectChat(_ value: Bool, restoreFocus: Bool = true, editingInterface: UUID? = nil, conversation: UUID? = nil)
    {
        editingInterfaceID = value ? editingInterface : nil
        if value {
            let destination = editingInterface ?? conversation
            if destination != conversationTaskID {
                if let current = conversationTaskID {
                    conversationDrafts[current] = command
                } else {
                    newTaskDraft = command
                }
                command = destination.map { conversationDrafts[$0] ?? "" } ?? newTaskDraft
            }
            conversationTaskID = destination
            conversationHistoryVisible = destination != nil
        }
        commandPanelVisible = value
        chatVisible = value
        if value {
            if let conversationTaskID {
                unreadReplyIDs.subtract(messages.lazy.filter { $0.taskID == conversationTaskID }.map(\.id))
            }
            dismissFeedback()
            commandFocusRequest += 1
        }
        onCommandPanel?(value, restoreFocus)
        refreshHover()
    }
    func dismissDetailsFromOutsideClick() {
        guard !collapsed, !pinned, !chatVisible, !menuTracking else { return }
        collapse()
    }
    func hide() {
        taskShelfVisible = false
        collapse()
        onHide?()
    }
    func showPage() {
        clickExpanded = true
        collapsed = false
        webExpanded = true
        onResize?(windowSize)
        onShow?()
    }
}
