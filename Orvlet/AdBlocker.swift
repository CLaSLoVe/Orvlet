import Foundation
import WebKit
import CryptoKit

@MainActor
enum AdBlocker {
    private static var compiled: Task<WKContentRuleList,Error>?
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return try await compiled.value }
        let task = Task<WKContentRuleList,Error> {
            guard let url = Bundle.main.url(forResource:"adblock-rules",withExtension:"json") else { throw AgentError.message("Advertising rules are missing.") }
            let data = try Data(contentsOf:url)
            let digest = SHA256.hash(data:data).prefix(8).map { String(format:"%02x",$0) }.joined()
            let identifier = "orvlet.ads." + digest
            let store = WKContentRuleListStore.default()!
            let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier:identifier) { list, _ in continuation.resume(returning:list) }
            }
            if let cached { return cached }
            guard let result = try await store.compileContentRuleList(forIdentifier:identifier,encodedContentRuleList:String(decoding:data,as:UTF8.self)) else { throw AgentError.message("Advertising rules could not be compiled.") }
            return result
        }
        compiled = task
        do { return try await task.value }
        catch { compiled = nil; throw error }
    }
    static func helper(enabled: Bool) -> String {
        guard let url = Bundle.main.url(forResource:"adblock-helper",withExtension:"js"),
              let source = try? String(contentsOf:url,encoding:.utf8) else { return "" }
        return source.replacingOccurrences(of:"__ORVLET_ADBLOCK_ENABLED__",with:enabled ? "true" : "false")
    }
}
