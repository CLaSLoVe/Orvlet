# Default browser inside Orvlet

Settings → General → Browser → Default browser uses the installed default Chromium-family browser in an Orvlet-owned process. Each task has its own live page. Opening the side screen streams that page's real rendered frames and forwards mouse, keyboard and IME input; collapsing it stops the frame stream while the page keeps running. Navigation, page reading, screenshots and playback tools operate on that same page.

The browser process uses Chromium's `--headless=new` mode to avoid creating an external desktop window. This is an implementation detail, not a text-only browsing experience: the interactive page is displayed inside Orvlet. It is not a native Chromium view embedded in AppKit. Browser-native dialogs, arbitrary JavaScript popup windows, file pickers, accessibility exposure of the remote DOM and browser chrome are not fully implemented. Ordinary `_blank` links open in the same task page. JavaScript dialogs are dismissed without showing an OS window.

Use the direct local build, `scripts/build.sh Release --system-browser`, which writes `dist/Orvlet-Browser.app`. This variant uses normal macOS application permissions, without App Sandbox. The original sandboxed build remains available and unchanged. Apple documents that [Process children inherit their parent's sandbox](https://developer.apple.com/documentation/foundation/process), so a signed sandboxed Orvlet cannot use this direct installed-browser host. Chromium's own renderer sandbox is never disabled; no `--no-sandbox` argument is used. Mac App Store distribution would need a different hosting architecture.

## Profile ownership and inheritance

The app uses `~/Library/Application Support/Orvlet/BrowserProfiles/<browser-bundle-id>`, never the user's active browser profile. The `.orvlet-profile` marker prevents accidental use of an unrelated nonempty directory. A random loopback debugging port and per-target sockets belong only to that process. No user browser tabs are attached or rearranged. Normal app termination asks the browser to flush its profile before quitting.

The default is a separate saved profile. Import is an explicit settings action with a confirmation naming the selected source profile. It copies login cookies using SQLite's online backup, including committed WAL data, and enabled store extension code where supported. It does not copy passwords, history, open tabs, website local storage or extension private settings. Disabled extensions stay excluded. The browser's encrypted key envelope is copied unchanged; Orvlet does not extract keychain keys or decrypt credentials. Some logins require storage beyond cookies or are bound to a particular profile/device and will still need sign-in.

An import is staged and applied on the next private browser start. The previous Orvlet profile remains in a sibling backup directory. This is a one-time snapshot, not continuing synchronization with the original browser. The user's original browser stays open and unchanged. No actual personal browser profile was imported during development or testing.

## Extensions and profiles

Open **Manage extensions** in the browser settings to manage extensions in Orvlet’s separate browser profile. Import support depends on the installed browser. Chrome imports cookies only. For built-in browsing, see the [native Chromium](native-chromium.md) and [WebKit](browser-extensions.md) guides.

The direct build stores its settings separately from the sandboxed edition. To recover previously configured model profiles, open **Settings → Models**, hold Option, choose **Restore previous profiles…**, then select the previous container’s Library folder. Recovery merges profiles and fills missing credentials locally.

## Background verification

After a Debug build, run `python3 scripts/check.py --skip-build system-browser state-machines`. The system-browser checks use a temporary profile and local test pages. They cover page input, session persistence, extension management, profile import and reconnection.
