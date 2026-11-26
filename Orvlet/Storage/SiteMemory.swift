import CryptoKit
import Foundation
import WebKit

/// A site observation applies to one read operation. Never store a URL path, query, page text or credential.
@MainActor
final class SiteMemory {
    enum Access: String, Codable {
        case loginRequired, unsupportedBrowser, userReported, apiUnauthorized, apiForbidden

        var description: String {
            switch self {
            case .loginRequired: "Sign-in required on the last visit"
            case .unsupportedBrowser: "The identity provider rejected this browser version"
            case .userReported: "You reported a sign-in problem"
            case .apiUnauthorized: "Public API required authentication (401)"
            case .apiForbidden: "Public API denied access (403)"
            }
        }
        var lifetime: TimeInterval { self == .unsupportedBrowser ? 7 * 86_400 : 86_400 }
    }

    struct BrowserProfile {
        let client: String
        let session: String
        let persistent: Bool
    }

    struct Route {
        let origin: String
        let key: String
        let label: String
        let login: Bool
        let logout: Bool
        init?(_ raw: String, client: String) {
            guard raw.utf8.count <= 4096, let url = URLComponents(string: raw),
                let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                let host = url.host?.lowercased(), !host.isEmpty,
                url.user == nil, url.password == nil else { return nil }
            let port = url.port.flatMap { ((scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80)) ? nil : $0 }
            origin = scheme + "://" + host + (port.map { ":\($0)" } ?? "")
            let parts = url.path.lowercased().split(separator: "/")
            let authParts: Set<Substring> = ["signin", "sign-in", "sign_in", "login", "log-in", "logon", "servicelogin", "authorize", "oauth2", "oauth"]
            login = parts.contains { authParts.contains($0) }
            logout = parts.contains { ["logout", "log-out", "signout", "sign-out"].contains($0) }
            // These labels are host-defined. Opaque route IDs also separate arbitrary entries on the same origin.
            let operation = parts.last.flatMap { ["favorites", "favourites", "bookmarks", "saved", "collections", "library", "account", "profile"].contains($0) ? String($0) : nil }
            label = client == "api" ? "Public API" : login ? "Sign-in" : operation?.capitalized ?? "Page"
            // Ignore analytics. A query or fragment may select a private resource or a different
            // action, so decline ambiguous routes. Identity providers often include a return URL.
            if !login || client == "api" {
                guard (url.queryItems ?? []).allSatisfy({
                    let name = $0.name.lowercased()
                    return name.hasPrefix("utm_") || ["gclid", "fbclid"].contains(name)
                }), (url.fragment ?? "").isEmpty else { return nil }
                guard parts.allSatisfy({ $0.utf8.count <= 40 && $0.range(of: #"^(?:[a-z_-]+|v[0-9]{1,2})$"#, options: .regularExpression) != nil }) else { return nil }
            }
            let route = [origin, client, url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath].joined(separator: "\n")
            key = SHA256.hash(data: Data(route.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Entry: Codable {
        let routeKey: String
        let origin: String
        let operation: String
        let access: Access
        let session: String?
        let provider: String?
        var taskID: UUID
        let date: Date
        var id: String { [routeKey, taskID.uuidString, session ?? "client"].joined(separator: ".") }
        var title: String { origin + " · " + operation }
        var detail: String { provider.map { access.description + " (" + $0 + ")" } ?? access.description }
    }
    private unowned let model: AppModel
    private var guest: [String: [Entry]] = [:]
    private var provisional = Set<UUID>()
    private var lastSweep = Date.distantPast
    var now: () -> Date = Date.init
    init(model: AppModel) { self.model = model }

    private func records(_ key: String) -> [Entry] {
        let disk = model.memoryDB.read([Entry].self, scope: "site", key: key) ?? []
        let live = disk.filter { now().timeIntervalSince($0.date) < $0.access.lifetime }
        if live.count != disk.count { store(live, key: key) }
        if let transient = guest[key] {
            let keep = transient.filter { now().timeIntervalSince($0.date) < $0.access.lifetime }
            guest[key] = keep.isEmpty ? nil : keep
        }
        return (live + (guest[key] ?? [])).filter { !model.hasPendingMemoryClear($0.taskID) }
    }
    @discardableResult private func store(_ rows: [Entry], key: String) -> Bool {
        if rows.isEmpty { return model.memoryDB.remove(scope: "site", key: key) }
        return model.memoryDB.write(rows, scope: "site", key: key)
    }
    private func record(_ access: Access, route: Route, taskID: UUID, profile: BrowserProfile? = nil, provider: String? = nil) {
        guard model.persistHistory, !model.hasPendingMemoryClear(taskID) else { return }
        let session = access == .loginRequired ? profile?.session : nil
        let volatile = session != nil && profile?.persistent == false
        if now().timeIntervalSince(lastSweep) >= 86_400 {
            lastSweep = now()
            for key in model.memoryDB.keys(scope: "site") { _ = records(key) }
        }
        if model.activeRequest?.placeholderID == taskID { provisional.insert(taskID) }
        let new = Entry(routeKey: route.key, origin: route.origin, operation: route.label, access: access, session: session, provider: provider, taskID: taskID, date: now())
        var rows = volatile ? guest[route.key] ?? [] : model.memoryDB.read([Entry].self, scope: "site", key: route.key) ?? []
        rows.removeAll { ($0.taskID == taskID && $0.session == session) || new.date.timeIntervalSince($0.date) >= $0.access.lifetime }
        rows.append(new)
        if volatile { guest[route.key] = rows } else { store(rows, key: route.key) }
    }
    func recordAPI(url: String, status: Int, taskID: UUID) {
        guard let route = Route(url, client: "api"), status == 401 || status == 403 else { return }
        record(status == 401 ? .apiUnauthorized : .apiForbidden, route: route, taskID: taskID)
    }
    func successfulAPI(_ url: String, checked: Date = Date()) {
        guard let route = Route(url, client: "api") else { return }
        erase({ $0.date <= checked }, keys: [route.key])
    }
    func adopt(_ prior: UUID, as id: UUID) {
        guard provisional.remove(prior) != nil else { return }
        func updated(_ rows: [Entry]) -> [Entry] {
            var values: [String: Entry] = [:]
            for var row in rows.sorted(by: { $0.date < $1.date }) {
                if row.taskID == prior { row.taskID = id }
                values[row.id] = row
            }
            return Array(values.values)
        }
        for key in Array(guest.keys) where guest[key]?.contains(where: { $0.taskID == prior }) == true {
            guest[key] = updated(guest[key] ?? [])
        }
        for key in model.memoryDB.keys(scope: "site") {
            if let rows = model.memoryDB.read([Entry].self, scope: "site", key: key), rows.contains(where: { $0.taskID == prior }) {
                store(updated(rows), key: key)
            }
        }
    }
    func hint(url: String, profile: BrowserProfile?) -> Entry? {
        guard model.persistHistory, let route = Route(url, client: profile?.client ?? "api") else { return nil }
        return records(route.key).filter { $0.session == nil || $0.session == profile?.session }.max { $0.date < $1.date }
    }

    /// Receipts are derived from a completed Orvlet navigation plus visible, structured page signals.
    func observe(requested: String, page: [String: Any], profile: BrowserProfile, taskID: UUID, verifiedReading: Bool = false) {
        guard model.persistHistory, let raw = page["url"] as? String,
            let intended = Route(requested, client: profile.client), let actual = Route(raw, client: profile.client),
            ["interactive", "complete"].contains(page["documentReady"] as? String ?? "") else { return }
        if actual.logout || intended.logout {
            invalidateSession(origin: intended.origin, profile: profile)
            return
        }
        if actual.login && (actual.origin == intended.origin || Self.identityHost(raw)) {
            if page["browserLoginRejected"] as? Bool == true {
                record(.unsupportedBrowser, route: intended, taskID: taskID, profile: profile, provider: actual.origin)
            } else if intended.key != actual.key && page["loginFormVisible"] as? Bool == true {
                record(.loginRequired, route: intended, taskID: taskID, profile: profile)
            }
        } else if intended.key == actual.key && !actual.login && page["loginFormVisible"] as? Bool != true &&
                    (verifiedReading || hasRequestedListing(route: intended, page: page)) {
            erase({ $0.session == nil || $0.session == profile.session }, keys: [intended.key])
        }
    }
    private func hasRequestedListing(route: Route, page: [String: Any]) -> Bool {
        guard page["signedInContentVisible"] as? Bool == true,
            let rows = page["readables"] as? [[String: Any]] else { return false }
        let labels: [String]
        switch route.label {
        case "Favorites", "Favourites", "Bookmarks", "Saved": labels = ["favorites", "favourites", "bookmarks", "saved", "收藏", "已保存"]
        case "Collections": labels = ["collections", "收藏", "合集"]
        case "Library": labels = ["library", "资料库", "資料庫"]
        default: return false
        }
        return rows.contains { row in
            guard ["h1", "heading"].contains(row["role"] as? String ?? ""), let value = row["text"] as? String else { return false }
            return labels.contains { value.localizedCaseInsensitiveContains($0) }
        }
    }
    private static func identityHost(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "idmsa.apple.com", "github.com"].contains(host)
    }
    func report(url: String, profile: BrowserProfile, taskID: UUID) -> Bool {
        guard let route = Route(url, client: profile.client) else { return false }
        record(.userReported, route: route, taskID: taskID, profile: profile)
        return hint(url: url, profile: profile)?.access == .userReported
    }
    func entries() -> [Entry] {
        Set(model.memoryDB.keys(scope: "site")).union(guest.keys).flatMap(records).sorted { $0.date > $1.date }
    }
    @discardableResult private func erase(_ shouldRemove: (Entry) -> Bool, keys: Set<String>) -> Bool {
        var ok = model.memoryDB.isAvailable
        for key in keys {
            if let rows = guest[key] {
                let keep = rows.filter { !shouldRemove($0) }
                guest[key] = keep.isEmpty ? nil : keep
            }
            if let rows = model.memoryDB.read([Entry].self, scope: "site", key: key) {
                let keep = rows.filter { !shouldRemove($0) }
                if keep.count < rows.count && !store(keep, key: key) { ok = false }
            }
        }
        return ok
    }
    @discardableResult func clear(taskID: UUID?) -> Bool {
        if let taskID {
            return erase({ $0.taskID == taskID }, keys: Set(model.memoryDB.keys(scope: "site")).union(guest.keys))
        } else {
            guest.removeAll()
            return model.memoryDB.remove(scope: "site", key: nil)
        }
    }
    @discardableResult func forget(_ entry: Entry) -> Bool { erase({ $0.id == entry.id }, keys: [entry.routeKey]) }
    func invalidateSession(origin: String? = nil, profile: BrowserProfile? = nil) {
        erase({ row in
            row.session != nil && (origin == nil || row.origin == origin) && (profile == nil || row.session == profile?.session)
        }, keys: Set(model.memoryDB.keys(scope: "site")).union(guest.keys))
    }
}

extension AppModel {
    func handleSiteReport(_ text: String, owner: UUID, reference: UUID?) -> Bool {
        let command = text.lowercased()
        guard !externalBrowser, command.range(of: #"^(?:请)?(?:记住|记一下|记下)|^(?:please )?remember\b"#, options: .regularExpression) != nil,
            command.range(of: #"(登不上|登录不了|无法登录|登入不了|不能登录|没法登录|couldn.t (?:log|sign) in|can.t (?:log|sign) in|could not (?:log|sign) in|unable to (?:log|sign) in)"#, options: .regularExpression) != nil,
            let profile = browser.siteMemoryProfile else { return false }
        let urls = AgentController.mentionedSiteURLs(text)
        var url = urls.count == 1 ? urls[0] : nil
        if urls.isEmpty, let reference,
            let source = sideTasks.first(where: { $0.id == reference && $0.kind == .web })?.sourceURL { url = source }
        guard let url, siteMemory.report(url: url, profile: profile, taskID: owner) else { return false }
        let chinese = text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        let reply = chinese ? "已记下你在这个入口遇到的登录问题。下次会重新检查。" : "Saved your sign-in report for this entry. I’ll check access on the next visit."
        deliverReply(reply, kind: .information, taskID: owner)
        return true
    }
    @discardableResult func forgetSiteMemory(taskID: UUID?) -> Bool { siteMemory.clear(taskID: taskID) }
    var siteMemoryItems: [MemoryListItem] {
        let titles = Dictionary(uniqueKeysWithValues: taskHistoryItems.map { ($0.id, $0.title) })
        return siteMemory.entries().map { entry in
            let source = titles[entry.taskID] ?? "Task conversation"
            return MemoryListItem(id: entry.id, kind: .site, title: entry.title, detail: entry.detail + " · " + source, updated: entry.date)
        }
    }
    func removeSiteMemoryItem(_ id: String) -> Bool {
        guard let entry = siteMemory.entries().first(where: { $0.id == id }) else { return false }
        return siteMemory.forget(entry)
    }
}

extension BrowserController {
    var siteMemoryProfile: SiteMemory.BrowserProfile? {
        if let host = systemPage?.host {
            guard host.native else { return nil }
            let session = NativeChromium.siteSession(profile: host.root, keepLogins: model.nativeExtensions.keepLogins)
            let version = Bundle.main.privateFrameworksURL
                .flatMap { Bundle(url: $0.appendingPathComponent("Chromium Embedded Framework.framework")) }
                .flatMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            return .init(client: "Chromium-" + version, session: session.id, persistent: session.persistent && model.nativeExtensions.keepLogins)
        }
        let dataStore = webView.configuration.websiteDataStore
        let persistent = dataStore.isPersistent
        return .init(client: "WebKit-" + ProcessInfo.processInfo.operatingSystemVersionString,
            session: persistent ? "webkit-default" : String(describing: ObjectIdentifier(dataStore)), persistent: persistent)
    }
}

extension AgentController {
    /// Include only the exact source the user supplied or the selected task actually owns.
    func siteHints() -> [[String: String]] {
        guard model.persistHistory else { return [] }
        let selected = model.sideTasks.first { $0.id == activeTaskID }
        var urls = [recovery.siteDestination, selected?.sourceURL].compactMap { $0 }
        let ownerBrowser: BrowserController? = selected?.kind == .web
            ? (activeTaskID == model.browser.id ? model.browser : model.parkedBrowsers[activeTaskID]) : nil
        let pending = ownerBrowser?.pendingSignInEntry
        if let pending { urls.insert(pending, at: 0) }
        let api = try? selected?.taskSurface?.apiData?.requestURL().absoluteString
        if let api { urls.append(api) }
        urls.append(contentsOf: Self.mentionedSiteURLs(currentRequest))
        var seen = Set<String>()
        var result: [[String: String]] = []
        for url in urls {
            var candidates = [model.siteMemory.hint(url: url, profile: nil)]
            if !model.externalBrowser, let profile = model.browser.siteMemoryProfile {
                candidates.append(model.siteMemory.hint(url: url, profile: profile))
            }
            for entry in candidates.compactMap({ $0 }) where seen.insert(entry.id).inserted {
                var hint = ["origin": entry.origin, "operation": entry.operation, "lastObserved": entry.date.ISO8601Format(), "observation": entry.detail]
                if url == pending && [.loginRequired, .userReported, .unsupportedBrowser].contains(entry.access) {
                    hint["ownedReturnEntry"] = url
                }
                result.append(hint)
                if result.count == 2 { return result }
            }
        }
        return result
    }

    static func siteHistoryTurn(_ hints: [[String: String]], turns: [[String: Any]]) -> [String: Any]? {
        guard !hints.isEmpty else { return nil }
        let lastTool = turns.last { $0["role"] as? String == "tool" }?["content"] as? String
        let lastAccess = lastTool.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["previousAccess"] as? [String: String]
        var lines = ["Earlier access, recheck before acting."]
        var turn: [String: Any]?
        for hint in hints.sorted(by: { ($0["lastObserved"] ?? "") > ($1["lastObserved"] ?? "") }).prefix(2) {
            guard let origin = hint["origin"], let operation = hint["operation"], let observation = hint["observation"],
                let when = hint["lastObserved"] else { continue }
            if lastAccess?["origin"] == origin && lastAccess?["operation"] == operation &&
                lastAccess?["observation"] == observation && lastAccess?["observed"] == when { continue }
            let label = [String(when.prefix(10)), origin, operation, observation].joined(separator: " · ")
            let detailed = hint["ownedReturnEntry"].map { label + " · return to " + $0 } ?? label
            for line in detailed == label ? [label] : [detailed, label] {
                let packet = ["role": "user", "content": (lines + [line]).joined(separator: "\n")]
                guard ModelContextBudget.estimate(packet) <= 200 else { continue }
                lines.append(line)
                turn = packet
                break
            }
        }
        turn?[ModelWire.contextPriorityKey] = 1
        return turn
    }

    static func mentionedSiteURLs(_ text: String) -> [String] {
        struct LinkDetector {
            static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }
        guard let detector = LinkDetector.detector else { return [] }
        let source = String(text.prefix(4000))
        return detector.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { $0.url?.absoluteString }.prefix(2).map { $0 }
    }
}
