# Security

Orvlet is under active development. There is no published security-audit claim or supported-version policy yet. Use the current source when reproducing a report.

Potentially sensitive areas include generated HTML/action validation, webpage observations sent to models, the optional authenticated loopback bridge, local credential storage, and Calendar writes.

## Reporting

Do not put credentials, private page captures, pairing tokens, or a working exploit against a real account in a public issue. Once a GitHub remote exists, use the repository's private vulnerability-reporting channel if it is enabled. If it is unavailable, ask the maintainer for a private reporting route before sharing sensitive details. No security email address or response-time promise has been established yet.

## Maintainer preparation

Before opening the repository publicly, enable GitHub private vulnerability reporting where available, choose a private contact route, and update this document. The local publication check rejects common credential patterns and private artifacts, but it does not replace a review of the actual staged contents.

## Local credential storage and publishing

API keys live in the app container’s Application Support directory, outside the repository and app bundle, with owner-only file permissions. They are plaintext local data. Orvlet does not read or write Keychain; upgrading from an older Keychain-based version requires entering keys again in Settings → Models. Existing Keychain entries are left untouched.

Enable the included local guards with `git config core.hooksPath .githooks`. The pre-commit hook scans the staged content; pre-push scans reachable Git history. Builds check source and release bundle contents. Run `python3 scripts/credential_check.py` to check the working tree. Guards never print secret values. Pattern detection supplements keeping credentials outside Git; it cannot identify every possible opaque secret or prevent deliberately bypassing hooks.
