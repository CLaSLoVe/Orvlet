#if DEBUG
    import Foundation
    import WebKit

    @MainActor
    enum BackgroundReadLiveCheck {
        static func run(_ model: AppModel) async {
            func emit(_ value: [String: Any]) {
                FileHandle.standardOutput.write(Data((JSONText.encode(value) + "\n").utf8))
            }
            do {
                // Experiment only: no production resource policy is enabled by this check.
                let rules = try await WKContentRuleListStore.default()!.compileContentRuleList(
                    forIdentifier: "orvlet.test.background-assets",
                    encodedContentRuleList: #"[{"trigger":{"url-filter":".*","resource-type":["image","font"]},"action":{"type":"block"}}]"#)!
                let modes = ["full", "projected", "projected_no_assets"]
                let queries = ["lofi hip hop radio", "EDM mix", "jazz music", "classical music"]
                var passed = true
                for round in 0..<2 {
                    for (index, query) in queries.enumerated() {
                        let rotation = (index + round) % 3
                        var order = Array(modes[rotation...] + modes[..<rotation])
                        if round == 1 { order.reverse() }
                        for mode in order {
                            let browser = BrowserController(model: model)
                            browser.setUserPlaybackPaused(true)
                            await browser.configureAdBlocking()
                            if mode == "projected_no_assets" { browser.webView.configuration.userContentController.add(rules) }
                            browser.webView.configuration.userContentController.addUserScript(WKUserScript(
                                source: "window.scanCount=0;const original=window.__orvlet.observe;window.__orvlet.observe=function(){window.scanCount++;return original.call(this)};",
                                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                            var url = URLComponents(string: "https://www.youtube.com/results")!
                            url.queryItems = [URLQueryItem(name: "search_query", value: query)]
                            let start = Date()
                            do {
                                let rows: [[String: Any]]
                                if mode == "full" {
                                    _ = try await browser.action(["action": "navigate", "url": url.url!.absoluteString])
                                    var found: [[String: Any]] = []
                                    repeat {
                                        _ = try await browser.observe()
                                        found = try await browser.webView.evaluateJavaScript("window.__orvlet.musicCandidates()") as? [[String: Any]] ?? []
                                        if !found.isEmpty { break }
                                        try await Task.sleep(for: .milliseconds(250))
                                    } while Date().timeIntervalSince(start) < 18
                                    rows = found
                                } else {
                                    rows = try await browser.navigateReading(
                                        to: url.url!.absoluteString, script: "window.__orvlet.musicCandidates()", timeout: 18
                                    ) { value in
                                        guard let rows = value as? [[String: Any]], !rows.isEmpty else { return nil }
                                        return rows
                                    }
                                }
                                let seconds = Date().timeIntervalSince(start)
                                let metrics = try await browser.webView.evaluateJavaScript("""
                                    (()=>{const n=performance.getEntriesByType('navigation')[0];const r=performance.getEntriesByType('resource');return {scans:window.scanCount,documentReady:document.readyState,responseStart:n?.responseStart??0,domReady:n?.domContentLoadedEventEnd??0,resourceCount:r.length,completedImages:[...document.images].filter(i=>i.complete&&i.naturalWidth>0).length,loadedFonts:[...document.fonts].filter(f=>f.status==='loaded').length};})()
                                    """) as? [String: Any] ?? [:]
                                emit(["sample": ["round": round, "query": query, "mode": mode, "seconds": seconds, "candidates": rows, "metrics": metrics]])
                                if rows.isEmpty { passed = false }
                            } catch {
                                passed = false
                                emit(["failure": ["round": round, "query": query, "mode": mode, "error": error.localizedDescription]])
                            }
                            browser.dispose()
                        }
                    }
                }
                emit(["ok": passed])
                if let suite = DebugHarness.pipelineSuite { model.preferences.removePersistentDomain(forName: suite) }
                exit(passed ? 0 : 1)
            } catch {
                emit(["error": error.localizedDescription]); exit(1)
            }
        }
    }
#endif
