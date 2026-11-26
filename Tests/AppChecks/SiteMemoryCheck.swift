#if DEBUG
import AppKit
import WebKit

@MainActor
enum SiteMemoryCheck {
    static func run(browserOnly: Bool = false) async throws -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { try StateMachineCheck.require(value, label, &checks) }
        let suite = "orvlet-site-memory-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: scratch) }
        let database = scratch.appendingPathComponent("memory.sqlite")
        let model = AppModel(defaults: defaults, memoryURL: database)
        model.isLiveTest = true
        model.settings.autoAdapt = false
        model.backgroundRequest = true
        defer { model.browser.dispose() }
        let base = "http://127.0.0.1:19244/site-memory"
        let url = base + "/favorites", publicPage = base + "/article"
        let agent = AgentController(model: model)
        agent.preparedBrowser = true
        let browser = model.browser
        browser.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 360)
        func visit(_ url: String) async throws -> [String: Any] {
            try await agent.executeBrowserTool("navigate", ["url": url], revision: agent.steeringRevision)
        }
        _ = try await visit(base + "/reset")
        let redirected = try await visit(url + "?utm_source=first")
        guard let profile = browser.siteMemoryProfile else { throw AppError.message("Missing owned test browser profile") }
        let reachedForm = model.lastObservation["loginFormVisible"] as? Bool == true
        let onLoginPage = (redirected["url"] as? String)?.hasSuffix("/site-memory/login") == true
        let currentHint = (redirected["previousAccess"] as? [String: String])?["observation"]
        let nextHint = model.siteMemory.hint(url: url + "?utm_source=second", profile: profile)?.access
        guard currentHint == SiteMemory.Access.loginRequired.description && nextHint == .loginRequired else {
            throw AppError.message("Site fixture redirect=\(onLoginPage) form=\(reachedForm) currentHint=\(currentHint != nil) laterHint=\(nextHint != nil) persistent=\(profile.persistent) sqlite=\(model.memoryDB.isAvailable)")
        }
        try check(onLoginPage && reachedForm, "A real redirect to a visible sign-in form is remembered across tracking parameters")
        let publicResult = try await visit(publicPage)
        try check(publicResult["previousAccess"] == nil && model.siteMemory.hint(url: publicPage, profile: profile) == nil,
            "An adjacent public article with a sign-in link remains accessible")
        agent.currentRequest = "Read " + url
        try check(agent.siteHints().count == 1, "A later request for the same protected operation receives only its scoped hint")
        _ = try await browser.evaluate("document.cookie='orvlet_memory_fixture=ready; Path=/site-memory'; true")
        let restored = try await visit(url)
        try check(restored["previousAccess"] == nil && model.siteMemory.hint(url: url, profile: profile) == nil,
            "A verified signed-in read removes the previous login requirement")
        _ = try await browser.evaluate("document.cookie='orvlet_memory_fixture=; Max-Age=0; Path=/site-memory'; true")

        if browserOnly {
            try check(browser.systemPage?.nativeBrowser != nil && profile.client.hasPrefix("Chromium-") &&
                profile.persistent == model.nativeExtensions.keepLogins, "CEF access memory follows the actual native profile and login-persistence mode")
            return checks
        }

        let first = UUID(), second = UUID()
        try check(model.handleSiteReport("记住 https://example.org/saved 我上次登不上", owner: first, reference: nil) &&
            model.siteMemory.hint(url: "https://example.org/saved", profile: profile)?.access == .userReported,
            "An explicit sign-in report is attributable to the human and scoped to their entry")
        let endpoint = "https://example.org/api/favorites"
        model.apiData = APIDataService(code: model.taskCode, fetch: { _ in
            let fixture = URL(string: "http://127.0.0.1:19244/blocked-source")!
            let (bytes, response) = try await URLSession.shared.data(from: fixture)
            try PublicDataClient.validateResponse(response)
            return try JSONSerialization.jsonObject(with: bytes)
        })
        agent.activeTaskID = first
        do {
            _ = try await agent.executeDataTool("inspect_api", ["url": endpoint], revision: agent.steeringRevision)
            throw AppError.message("Expected fixture API denial")
        } catch let failure as SourceReadFailure {
            _ = try agent.recover(failure, tool: "inspect_api", arguments: ["url": endpoint])
        }
        let reopened = AppModel(defaults: defaults, memoryURL: database)
        let memory = reopened.siteMemory
        try check(memory.hint(url: "https://example.org/saved", profile: profile)?.access == .userReported,
            "A requested human report remains available after restart")
        let longHost = Array(repeating: String(repeating: "a", count: 50), count: 3).joined(separator: ".")
        func packet(_ host: String, _ when: String) -> [String: String] {
            ["origin": "https://" + longHost + host, "operation": "Public API", "observation": "Access denied (403)", "lastObserved": when]
        }
        let old = packet(".old.example", "2026-01-01"), recent = packet(".new.example", "2026-01-02")
        let turn = AgentController.siteHistoryTurn([old, recent], turns: [])
        let text = turn?["content"] as? String ?? ""
        try check(turn?[ModelWire.contextPriorityKey] as? Int == 1 && ModelContextBudget.estimate(["role": "user", "content": text]) <= 200 &&
            text.contains(".new.example") && !text.contains(".old.example"), "Two long site candidates stay under 200 tokens and preserve the newer source")
        try check(memory.hint(url: endpoint, profile: nil)?.access == .apiForbidden
            && memory.hint(url: endpoint, profile: profile) == nil
            && memory.hint(url: endpoint + "?resource=private", profile: nil) == nil
            && memory.hint(url: "https://example.org/api/public", profile: nil) == nil,
            "A typed API denial survives a restart and applies only to the same public API operation")
        memory.recordAPI(url: endpoint, status: 401, taskID: second)
        reopened.forgetSiteMemory(taskID: second)
        try check(memory.hint(url: endpoint, profile: nil)?.taskID == first, "Removing one task preserves independent site evidence")
        memory.successfulAPI(endpoint)
        try check(memory.hint(url: endpoint, profile: nil) == nil, "Successful acquisition retracts the exact API denial")
        memory.recordAPI(url: endpoint, status: 429, taskID: second)
        try check(memory.hint(url: endpoint, profile: nil) == nil, "A rate limit creates no login memory")

        let guest = SiteMemory.BrowserProfile(client: "Chromium-test", session: "guest", persistent: false)
        let other = SiteMemory.BrowserProfile(client: "Chromium-test", session: "another", persistent: false)
        let login: [String: Any] = ["url": base + "/login", "documentReady": "complete", "loginFormVisible": true]
        let note = "https://example.org/bookmarks"
        try check(memory.report(url: note, profile: guest, taskID: first) &&
            model.siteMemory.hint(url: note, profile: other)?.access == .userReported,
            "An explicit guest report persists by client without storing guest authentication state")
        memory.observe(requested: note, page: ["url": note, "documentReady": "complete"], profile: other, taskID: first, verifiedReading: true)
        try check(model.siteMemory.hint(url: note, profile: guest) == nil, "A verified newer read supersedes a human-reported login problem")
        memory.observe(requested: url, page: login, profile: guest, taskID: first)
        memory.observe(requested: url, page: login, profile: other, taskID: second)
        memory.observe(requested: url, page: ["url": url, "documentReady": "complete"], profile: other, taskID: second, verifiedReading: true)
        try check(memory.hint(url: url, profile: guest)?.access == .loginRequired && memory.hint(url: url, profile: other) == nil
            && model.siteMemory.hint(url: url, profile: guest) == nil, "Guest observations are in-memory and a success in another session cannot erase them")
        memory.observe(requested: url, page: ["url": base + "/login", "documentReady": "complete", "browserLoginRejected": true], profile: guest, taskID: first)
        let updated = SiteMemory.BrowserProfile(client: "Chromium-upgraded", session: guest.session, persistent: false)
        try check(memory.hint(url: url, profile: updated) == nil, "A browser upgrade invalidates the previous compatibility conclusion")
        let future = Date().addingTimeInterval(8 * 86_400)
        memory.now = { future }
        try check(memory.hint(url: url, profile: guest) == nil, "Stale login and unsupported-browser observations expire")
        return checks
    }
}
#endif
