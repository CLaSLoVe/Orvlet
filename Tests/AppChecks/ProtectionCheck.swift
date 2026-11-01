#if DEBUG
import AppKit
import WebKit

@MainActor
enum ProtectionCheck {
    static func run(_ model: PetModel, delegate: AppDelegate) async {
        model.isLiveTest = true; model.persistHistory = false; model.settings.autoAdapt = false
        model.settings.reduceMotion = true; model.settings.expandOnHover = false
        var checks: [String] = []
        func check(_ value: Bool,_ name: String) throws { guard value else { throw AgentError.message(name) }; checks.append(name) }
        func pause(_ seconds: Double = 0.4) async throws { try await Task.sleep(for:.seconds(seconds)) }
        do {
            let old = try JSONDecoder().decode(ModelSettings.self,from:Data("{}".utf8))
            try check(old.blockAds && old.inactiveStackOpacity == 0.55,"Existing preferences gain enabled blocking and 55% idle opacity")
            model.settings.inactiveStackOpacity = 0.4
            let restored = try JSONDecoder().decode(ModelSettings.self,from:JSONEncoder().encode(model.settings))
            try check(restored.inactiveStackOpacity == 0.4,"Opacity survives settings encoding")
            _ = try model.startTimer(seconds:600,title:"Quiet timer")
            model.collapse(); model.selectChat(false,restoreFocus:false)
            model.pointerChanged(false); model.stackHasKeyboardFocus = false
            try await pause(3.4)
            try check(model.stackDimmed && abs(delegate.panel.alphaValue-0.4)<0.01,"Unattended stack applies configured alpha to the entire native window")
            model.pointerChanged(true); try await pause()
            try check(delegate.panel.alphaValue == 1,"Pointer entry restores full opacity")
            model.pointerChanged(false); model.menuTracking = true; try await pause(3.2)
            try check(!model.stackDimmed,"Context menu interaction prevents fading")
            model.menuTracking = false; model.selectChat(true); try await pause(3.2)
            try check(delegate.panel.alphaValue == 1 && delegate.commandPanel?.alphaValue == 1,"Independent command input keeps both interfaces readable")
            model.selectChat(false,restoreFocus:false); model.taskShelfVisible = true; try await pause(3.2)
            try check(delegate.panel.alphaValue == 1,"Expanded task list stays fully readable")
            model.taskShelfVisible = false; model.stackHasKeyboardFocus = true; try await pause(3.2)
            try check(!model.stackDimmed,"Keyboard focus prevents fading")
            model.stackHasKeyboardFocus = false; model.pointerChanged(false); model.settings.inactiveStackOpacity = 1
            try await pause(3.4)
            try check(model.stackDimmed && delegate.panel.alphaValue == 1,"100% setting keeps unattended stack opaque")
            model.settings.inactiveStackOpacity = 0.55
            try await pause()
            try check(abs(delegate.panel.alphaValue-0.55)<0.01,"Changing opacity updates an already idle window immediately")

            model.settings.blockAds = true
            let browser = BrowserController(model:model)
            defer { browser.dispose() }
            browser.webView.loadHTMLString("<html><body><div id='ad' class='advertisement'>Ad</div><button id='normal'>Pause music</button></body></html>",baseURL:URL(string:"http://127.0.0.1:19244"))
            for _ in 0..<60 {
                try await pause(0.1)
                if (try? await browser.webView.evaluateJavaScript("!!document.querySelector('#ad')")) as? Bool == true { break }
            }
            let hidden = try await browser.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#ad')).display==='none' && getComputedStyle(document.querySelector('#normal')).display!=='none'") as? Bool
            try check(hidden == true && model.adBlockingError == nil,"Bundled native rules compile and hide ads before first page finishes while preserving controls")
            model.settings.blockAds = false; await browser.configureAdBlocking()
            browser.webView.loadHTMLString("<html><body><div id='ad' class='advertisement'>Ad</div></body></html>",baseURL:URL(string:"http://127.0.0.1:19244"))
            try await pause(1)
            try check(try await browser.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#ad')).display!=='none'") as? Bool == true,"Disabling filtering restores normal page content after reload")
            model.settings.blockAds = true; await browser.configureAdBlocking()
            browser.webView.loadHTMLString("<html><body><div id='ad' class='advertisement'>Ad</div></body></html>",baseURL:URL(string:"http://127.0.0.1:19244"))
            try await pause(1)
            try check(try await browser.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#ad')).display==='none'") as? Bool == true,"Re-enabling filtering restores native ad hiding")
            try check(browser.webView.configuration.userContentController.userScripts.count == 2,"Toggling protection does not duplicate browser scripts")

            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(WKUserScript(source:AdBlocker.helper(enabled:true),injectionTime:.atDocumentStart,forMainFrameOnly:true))
            let web = WKWebView(frame:NSRect(x:0,y:0,width:400,height:200),configuration:config)
            web.loadHTMLString("<html><body><div class='html5-video-player'><video></video><button class='ytp-skip-ad-button' onclick='window.clicks++'>Skip</button></div><script>window.clicks=0;window.paused=true;Object.defineProperty(document.querySelector('video'),'paused',{get:()=>window.paused});</script></body></html>",baseURL:URL(string:"https://www.youtube.com/"))
            try await pause(1.3)
            try check(try await web.evaluateJavaScript("window.clicks===0 && !window.__orvletAds.isAd()") as? Bool == true,"Skip helper ignores ordinary content")
            _ = try await web.evaluateJavaScript("document.querySelector('div').classList.add('ad-showing')")
            try await pause(1.2)
            try check(try await web.evaluateJavaScript("window.clicks===0 && window.__orvletAds.isAd()") as? Bool == true,"Paused advertisement is detected but never resumed by skipping")
            _ = try await web.evaluateJavaScript("window.paused=false")
            try await pause(1.2)
            try check(try await web.evaluateJavaScript("window.clicks>0") as? Bool == true,"Playing skippable advertisement uses the available skip button")
            _ = try await web.evaluateJavaScript("window.__orvletAds.setEnabled(false);window.clicks=0")
            try await pause(1.8)
            try check(try await web.evaluateJavaScript("window.clicks===0") as? Bool == true,"Disabled helper stops clicking skip controls")
            web.loadHTMLString("",baseURL:nil)
            delegate.showSettings(); try await pause()
            if let settings = delegate.settingsWindow { try await SideScreenCheck.snapshot(settings,path:"/tmp/orvlet-protection-settings.png") }
            try JSONSerialization.data(withJSONObject:["ok":true,"checks":checks,"scope":"Local WebKit fixtures; no claim of universal YouTube ad removal"],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-protection-checks.json"))
            exit(0)
        } catch {
            try? JSONSerialization.data(withJSONObject:["ok":false,"checks":checks,"error":error.localizedDescription],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-protection-checks.json")); exit(1)
        }
    }
}
#endif
