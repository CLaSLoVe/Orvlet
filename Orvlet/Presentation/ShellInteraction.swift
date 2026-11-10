import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func pointerChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        refreshStackAttention()
        if !inside { previewHovered = false }
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
        guard !taskShelfVisible, !pinned, !chatVisible, !clickExpanded else { return }
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
                    self.pointerInside == entering
                else { return }
                if entering {
                    guard self.settings.expandOnHover, self.previewHovered, self.activeInteractions == 0,
                        self.pressedMouseButtons == 0
                    else { return }
                    self.reveal(preview: true)
                } else {
                    self.collapse()
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
    func collapse() {
        taskShelfVisible = false
        pinned = false
        clickExpanded = false
        hoverTask?.cancel()
        collapsed = true
        webExpanded = false
        onResize?(windowSize)
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
            hasUnreadReply = false
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
