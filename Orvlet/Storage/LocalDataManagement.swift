import Foundation
import WebKit

enum LocalDataKind: String, CaseIterable, Identifiable {
    case interfaces, web, pages, conversations
    var id: String { rawValue }
    var title: String {
        switch self {
        case .interfaces: "Saved interfaces"
        case .web: "Web cache"
        case .pages: "Recent pages"
        case .conversations: "Chat messages"
        }
    }
    var symbol: String {
        switch self {
        case .interfaces: "square.grid.2x2"
        case .web: "globe"
        case .pages: "clock.arrow.circlepath"
        case .conversations: "bubble.left.and.bubble.right"
        }
    }
    var detail: String {
        switch self {
        case .interfaces: "User designs and reusable cards"
        case .web: "Temporary page resources"
        case .pages: "Visited pages and resume points"
        case .conversations: "Saved messages and drafts"
        }
    }
    var confirmation: String {
        switch self {
        case .interfaces:
            "Remove saved user designs and reset reuse to the built-in defaults? The six built-in tools remain available. Open tasks stay as they are."
        case .web:
            "Remove cached page resources? Sign-ins, saved tools and conversations stay. Pages may reload resources next time."
        case .pages: "Remove recent-page history and saved resume points? Open pages and conversations stay."
        case .conversations:
            "Remove all saved chat messages and drafts? Tasks, built-in tools and model settings stay. This cannot be undone."
        }
    }
}

enum LocalDataSize {
    static func label(_ bytes: Int) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    /// Metadata only, limited to this application's network-cache directories.
    static func webCacheBytes() -> Int? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let roots = [
            caches.appendingPathComponent("WebKit/NetworkCache"),
            caches.appendingPathComponent(bundle + "/WebKit/NetworkCache"),
            library.appendingPathComponent("WebKit/WebsiteData/NetworkCache"),
            library.appendingPathComponent("WebKit/" + bundle + "/WebsiteData/NetworkCache"),
        ]
        var total = 0
        var found = false
        var failed = false
        for root in roots where fm.fileExists(atPath: root.path) {
            found = true
            guard
                let files = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in
                        failed = true
                        return false
                    })
            else { return nil }
            for case let file as URL in files {
                guard
                    let values = try? file.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey,
                    ])
                else { return nil }
                if values.isSymbolicLink == true {
                    files.skipDescendants()
                    continue
                }
                if values.isRegularFile == true { total += values.fileAllocatedSize ?? 0 }
            }
        }
        return !failed && (found || fm.isReadableFile(atPath: caches.path)) ? total : nil
    }
}

extension AppModel {
    var canClearChatMessages: Bool {
        !busy && queuedTaskRequests.isEmpty && globalRoutingTask == nil && !buildingSurface && interfaceJobs.isEmpty
            && taskActionJobs.isEmpty
    }
    var canClearLocalData: Bool { canClearChatMessages }
    func storedBytes(for kind: LocalDataKind) -> Int {
        switch kind {
        case .interfaces:
            (adaptive.cache.defaults.data(forKey: "surfaces.v1")?.count ?? 0) + interfaceMemory.storedBytes
        case .pages: (preferences.data(forKey: "history")?.count ?? 0) + sessions.storedBytes
        case .conversations: preferences.data(forKey: "conversation.v1")?.count ?? 0
        case .web: 0  // The asynchronous browser estimate is separate; never present this as a measured size.
        }
    }
    @discardableResult func clearChatMessages(taskID: UUID? = nil) -> Bool {
        guard canClearChatMessages else { return false }
        if let taskID {
            messages.removeAll { $0.taskID == taskID }
            conversationDrafts[taskID] = nil
            if conversationTaskID == taskID { command = "" }
        } else {
            messages.removeAll()
            conversationDrafts.removeAll()
            newTaskDraft = ""
            command = ""
        }
        // Explicitly persist deletions, including when the last message is removed.
        if messages.isEmpty {
            preferences.removeObject(forKey: "conversation.v1")
        } else if let data = try? JSONEncoder().encode(messages) {
            preferences.set(data, forKey: "conversation.v1")
        }
        if taskID == nil || agent.calendarClarificationTaskID == taskID {
            agent.calendarClarification = nil
            agent.calendarClarificationTaskID = nil
            agent.clarificationPrefix = nil
        }
        onCommandResize?(commandWindowHeight)
        return true
    }
    @discardableResult func clearLocalData(_ kind: LocalDataKind) async -> Bool {
        guard canClearLocalData else { return false }
        switch kind {
        case .interfaces:
            adaptive.invalidate()
            adaptive.cache.clear()
            interfaceMemory.resetUserRecipes()
            agent.preparedRequest = nil
        case .web: await browser.clearResourceCache()
        case .pages: clearRecentSessions()
        case .conversations: return clearChatMessages()
        }
        return true
    }
}
