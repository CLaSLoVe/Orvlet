#if DEBUG
    import Foundation
    import WebKit

    @MainActor
    enum BrowserReadCheck {
        static func run(_ model: AppModel) async throws -> [String] {
            let browser = BrowserController(model: model)
            browser.setUserPlaybackPaused(true)
            defer { browser.dispose() }
            await browser.configureAdBlocking()
            // Fail if targeted reading accidentally calls the full-page extractor.
            browser.webView.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__orvlet.observe = () => { throw Error('Unexpected full-page scan'); };",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            var checks: [String] = []
            for expected in ["first", "second"] {
                let result: String = try await browser.navigateReading(
                    to: "http://127.0.0.1:19244/deferred-reading?" + expected,
                    script: "document.querySelector('#reading')?.textContent || null"
                ) { $0 as? String }
                guard result == expected else { throw AppError.message("Reading returned the previous document") }
                let ready = try await browser.webView.evaluateJavaScript("document.readyState") as? String
                guard ready == "interactive" else { throw AppError.message("Reading waited for irrelevant slow resources") }
                checks.append("Targeted read waits for fresh requested data, without scanning or loading unrelated resources")
            }
            var timedOut = false
            do {
                let _: String = try await browser.navigateReading(
                    to: "http://127.0.0.1:19244/deferred-reading", script: "null", timeout: 0.5
                ) { $0 as? String }
            } catch is PageReadUnavailable { timedOut = true }
            guard timedOut else { throw AppError.message("Missing page data was accepted") }
            checks.append("Unavailable projected data has a bounded failure, not a fabricated result")
            return checks
        }
    }
#endif
