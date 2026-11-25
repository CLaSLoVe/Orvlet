# Browser extensions

The [native Chromium edition](native-chromium.md) ships without extensions. Install an unpacked Manifest V3 extension in Settings → General → Browser → Extensions. The [default-browser backend](system-browser.md) uses its own profile. The instructions below apply to the WebKit edition.

Built-in can import compatible Chrome/Safari WebExtensions using Apple's native `WKWebExtension` runtime on macOS 15.4 or later. This retains the system WebKit browser. It does not embed Chrome or inherit extensions, cookies or tabs from the user's Chrome profile.

## Install and use

1. Obtain the extension's ZIP from its publisher, or an unpacked extension directory containing `manifest.json` at its root.
2. Open Settings → General → Browser extensions → Import.
3. Review the named API and website permissions, then select Install.
4. Reload an open page. Use the puzzle icon in the source-page toolbar, or Open extension in the settings row, to open its action popup.

The settings switch enables/disables an extension. Remove uninstalls its package and extension storage. Names, versions and short package fingerprints distinguish same-name instances; importing the identical package twice is rejected. Optional permissions are not silently granted. Required permission changes require a fresh import and review.

## Supported boundary

- Native content scripts, background content, storage and declarative network rules use WebKit's implementation.
- Only Orvlet's site browsing surfaces join the extension controller. Generated task cards and the user's external browsers do not.
- The host supplies its owned tab/window enumeration and action popup. It does not claim the full Chrome browser API surface.
- Chrome Web Store one-click installation, CRX imports, automatic extension updates, Chrome-only APIs, native messaging and full browser-tab management are not implemented.
- Compatibility varies by extension and version. A passing Manifest V3 blocking fixture does not establish compatibility with full extensions.
- Disabling unloads the extension. Previously executed scripts can leave document changes until that page is reloaded.
- macOS versions below 15.4 retain existing browsing and built-in ad blocking without extension installation.
