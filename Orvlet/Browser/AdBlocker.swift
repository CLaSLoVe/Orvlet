import CryptoKit
import Foundation
import WebKit

@MainActor
final class AdBlocker {
    private var installedRules: WKContentRuleList?
    var hasRules: Bool { installedRules != nil }

    static func installHelper(in controller: WKUserContentController, enabled: Bool) {
        controller.addUserScript(WKUserScript(
            source: helper(enabled: enabled), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func applyRules(to web: WKWebView, model: AppModel) async {
        let controller = web.configuration.userContentController
        if !model.settings.blockAds {
            if let installedRules { controller.remove(installedRules) }
            installedRules = nil
            model.adBlockingError = nil
            return
        }
        guard installedRules == nil else { return }
        do {
            let rules = try await Self.ruleList()
            guard model.settings.blockAds, installedRules == nil else { return }
            controller.add(rules)
            installedRules = rules
            model.adBlockingError = nil
        } catch {
            if model.settings.blockAds {
                model.adBlockingError = "Ad blocking could not start. Try reopening Orvlet."
            }
        }
    }

    func update(_ web: WKWebView, model: AppModel) async {
        await applyRules(to: web, model: model)
        _ = try? await web.evaluateJavaScript("window.__orvletAds?.setEnabled(\(model.settings.blockAds))")
    }

    private static var compiled: Task<WKContentRuleList, Error>?
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return try await compiled.value }
        let task = Task<WKContentRuleList, Error> {
            guard let url = Bundle.main.url(forResource: "adblock-rules", withExtension: "json") else {
                throw AppError.message("Advertising rules are missing.")
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            let identifier = "orvlet.ads." + digest
            let store = WKContentRuleListStore.default()!
            let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list)
                }
            }
            if let cached { return cached }
            guard
                let result = try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: String(decoding: data, as: UTF8.self))
            else { throw AppError.message("Advertising rules could not be compiled.") }
            return result
        }
        compiled = task
        do { return try await task.value } catch {
            compiled = nil
            throw error
        }
    }
    static func helper(enabled: Bool) -> String {
        guard let url = Bundle.main.url(forResource: "adblock-helper", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return source.replacingOccurrences(of: "__ORVLET_ADBLOCK_ENABLED__", with: enabled ? "true" : "false")
    }
}
