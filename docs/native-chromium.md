# Native Chromium distribution

`Orvlet-Chromium.app` replaces the built-in **website** renderer with a real CEF/Chromium `NSView`. Generated task cards still use WebKit. The existing external-browser mode remains available separately.

This distribution is currently Apple silicon only. The build pins and verifies CEF 156.0.32 / Chromium 156.0.8078.109. It ships without browser extensions.

## Presentation and ownership

Each task owns one browser and native child view. Opening the source attaches that view to the existing Orvlet shell; returning to the card parks it in an Orvlet-owned, nonactivating panel outside the desktop. Playback and agent operations continue against the same page. This path does not use headless mode, JPEG screencasting, or remote pointer/text forwarding. CDP remains the agent/control interface.

Native view bounds match compositor dimensions. Do not scale an ancestor `NSView` to fake a wider browser: that scales Cocoa hit testing without scaling Chromium's accelerated surface. The card uses its content size. Opening the source animates the shell to the saved browser dimensions.

The main transitions are:

| State | Trigger | Result |
| --- | --- | --- |
| Opening | First task navigation | Create a native view and bind its unique CDP target |
| Parked | Card/collapsed/background task | Keep the renderer in its private parking panel |
| Attached | Open source | Move that same view into the current shell viewport |
| Parked | Hide/dismantle source | Only the viewport that owns the view may park it |
| Disconnected | A page's control connection fails | Close only that task's renderer; navigation may create a replacement |
| Closing | Dispose task or quit | Cancel work, request CEF close, then remove the child view hierarchy |
| Closed | CEF `on_before_close` | Release browser references and remove it from the runtime registry |

Detached/stale viewports cannot reclaim a currently displayed renderer. Stale CDP callbacks cannot tear down a replacement connection. Closing a browser never sends a close request to the Orvlet shell.

## macOS lifecycle

The shell starts without Chromium. A paused session restores its card from local data. Opening or operating its page, or explicitly resuming playback at launch, starts Chromium in the selected storage mode. The first request briefly stops the AppKit loop so CEF can install its run-loop observers before the next loop entry. Orvlet reinstalls its delegate after CEF initialization. Existing windows continue to use the same SwiftUI views. Native quit closes and flushes the browsers, stops the AppKit loop, and calls `cef_shutdown` after the loop returns.

The external message pump uses one-shot timers, CEF's scheduling callback, and a reentrancy guard. A fallback timer follows CEF's external-pump example. Helpers use CEF's macOS sandbox loader; no `--no-sandbox` flag is used. The outer application's App Sandbox is disabled for this direct-distribution variant.

CEF's C API adopts incoming reference-counted parameters. In particular, do not release a client or completion callback immediately after transferring it into a CEF call. Handler getters return an owned reference. `on_before_close` is the authoritative end of a browser's lifetime.

## Profiles and extensions

The built-in browser starts a fresh guest session by default. Tasks can share a website login during that session. For logins that should survive a restart, enable **Settings → General → Browser → Remember website logins**. That choice uses Orvlet’s existing macOS Keychain-protected Chromium profile on the next browser start. Turning it off selects guest browsing again and preserves the saved profile.

In **Settings → General → Browser → Extensions**, select **Install extension…**, choose an unpacked Manifest V3 folder with `manifest.json` at its root, review the requested permissions and select **Install**. For ad blocking, users can install a compatible content blocker of their choice. Changes to a running browser take effect after restarting Orvlet. The extension row provides enable, disable, options (when provided), and removal.

Package files and the extension list live under Orvlet’s Application Support directory. Imports are fingerprinted before and after copying and again at installation. The importer rejects duplicate packages and symbolic links. The embedded browser supports a subset of Chrome’s extension interfaces, so compatibility depends on which APIs the extension uses.

## Build and background checks

Run native builds and checks outside the execution sandbox:

```sh
python3 scripts/build-native-chromium.py Debug
python3 scripts/check.py --skip-build \
  --app .build-native/Build/Products/Debug/Orvlet.app/Contents/MacOS/Orvlet \
  native-browser state-machines
python3 scripts/build-native-chromium.py Release
```

The build scans application/build/test sources, verifies packaged third-party files byte-for-byte against SHA-256-pinned public archives, and scans every other bundled file with the unchanged credential guard. It signs and verifies the separate output bundle, and never launches or replaces the user's running application.

Native regression checks use an isolated temporary profile, local fixtures, muted media and offscreen panels. Separate launches exercise guest storage isolation, opt-in login persistence, and a local extension’s installation, content script, request blocking, options and disabled state.

The shell QA image is a composition of an actual SwiftUI capture and an actual Chromium compositor capture at the measured native-view bounds. AppKit's bitmap cache does not include Chromium's accelerated layer. This composition exists only in the test artifact; the application displays the live native view directly.

References: [CEF macOS external pump](https://github.com/chromiumembedded/cef/blob/master/tests/shared/browser/main_message_loop_external_pump_mac.mm), [CEF native macOS view lifecycle](https://github.com/chromiumembedded/cef/blob/master/libcef/browser/native/browser_platform_delegate_native_mac.mm), [Chromium background test permission flags](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md).
