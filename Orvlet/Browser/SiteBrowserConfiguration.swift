import WebKit

extension WKWebViewConfiguration {
    /// Both browsing surfaces use the system WebKit engine and the same site identity.
    @MainActor static func orvletSiteBrowser() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if DEBUG
            if CommandLine.arguments.contains("--isolated-web-session") { config.websiteDataStore = .nonPersistent() }
        #endif
        // macOS WebKit freezes its engine token at 605.1.15. Its default embedded
        // UA omits the Safari product version used by sites for compatibility checks.
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
            let version = Bundle(url: safari)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil {
            config.applicationNameForUserAgent = "Version/" + version + " Safari/605.1.15"
        }
        config.preferences.isElementFullscreenEnabled = false
        WindowPlayer.install(in: config.userContentController)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }
}
