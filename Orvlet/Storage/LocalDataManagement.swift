import Foundation
import WebKit

struct MemoryListItem: Identifiable {
    enum Kind { case task, site }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let updated: Date
}

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
        case .pages: "Visited pages, resume points and website experience"
        case .conversations: "Saved messages, drafts and task memory"
        }
    }
    var confirmation: String {
        switch self {
        case .interfaces:
            "Remove saved user designs and reset reuse to the built-in defaults? The six built-in tools remain available. Open tasks stay as they are."
        case .web:
            "Remove cached page resources? Sign-ins, saved tools and conversations stay. Pages may reload resources next time."
        case .pages: "Remove recent-page history, saved resume points and website experience?"
        case .conversations:
            "Remove all messages, drafts, task memory and website experience from these conversations? This cannot be undone."
        }
    }
}

enum LocalDataSize {
    static func label(_ bytes: Int) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    /// Metadata only, limited to this application's network-cache directories.
    nonisolated static func webCacheBytes() -> Int? {
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
        case .pages: (preferences.data(forKey: "history")?.count ?? 0) + sessions.storedBytes + memoryDB.bytes(scope: "site")
        case .conversations: (preferences.data(forKey: "conversation.v1")?.count ?? 0) + memoryDB.bytes(scope: "task")
        case .web: 0  // The asynchronous browser estimate is separate; never present this as a measured size.
        }
    }
    @discardableResult func clearChatMessages(taskID: UUID? = nil) -> Bool {
        guard canClearChatMessages else { return false }
        let receipts = Set(messages.filter { $0.pendingReminder != nil && (taskID == nil || $0.taskID == taskID) }.map(\.id))
        removeReminders { receipts.contains($0.id) }
        let cleared = eraseConversationData(taskID)
        if taskID == nil || agent.calendarClarificationTaskID == taskID {
            agent.calendarClarification = nil
            agent.calendarClarificationTaskID = nil
            agent.clarificationPrefix = nil
        }
        onCommandResize?(commandWindowHeight)
        return cleared
    }

    private var pendingConversationClears: [String: Bool] {
        preferences.dictionary(forKey: "pendingConversationClear.v1") as? [String: Bool] ?? [:]
    }

    func hasPendingMemoryClear(_ taskID: UUID) -> Bool {
        let journal = pendingConversationClears
        return journal["all"] != nil || journal[taskID.uuidString] != nil
    }

    private func setClearPhase(_ phase: Bool?, for key: String) {
        var journal = pendingConversationClears
        journal[key] = phase
        if journal.isEmpty { preferences.removeObject(forKey: "pendingConversationClear.v1") }
        else { preferences.set(journal, forKey: "pendingConversationClear.v1") }
        preferences.synchronize()
    }

    // Journal both stores. Once text is gone, a storage retry only clears the derived records.
    @discardableResult func eraseConversationData(_ taskID: UUID?) -> Bool {
        let key = taskID?.uuidString ?? "all"
        setClearPhase(true, for: key)
        return finishConversationClear(taskID, eraseText: true)
    }

    private func finishConversationClear(_ taskID: UUID?, eraseText: Bool) -> Bool {
        let key = taskID?.uuidString ?? "all"
        if eraseText {
            eraseConversationText(taskID)
            setClearPhase(false, for: key)
        }
        let tasksCleared = forgetTaskMemory(taskID)
        let sitesCleared = forgetSiteMemory(taskID: taskID)
        guard tasksCleared && sitesCleared else { return false }
        setClearPhase(nil, for: key)
        return true
    }

    private func eraseConversationText(_ taskID: UUID?) {
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
    }

    func resumePendingConversationClear() {
        guard !(preferences === UserDefaults.standard && MemoryDatabase.runsChecks) else { return }
        for (key, eraseText) in pendingConversationClears {
            if key == "all" { _ = finishConversationClear(nil, eraseText: eraseText) }
            else if let taskID = UUID(uuidString: key) {
                _ = finishConversationClear(taskID, eraseText: eraseText)
            }
        }
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
        case .pages:
            guard forgetSiteMemory(taskID: nil) else { return false }
            clearRecentSessions()
        case .conversations: return clearChatMessages()
        }
        return true
    }
}
