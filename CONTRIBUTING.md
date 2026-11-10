# Contributing to Orvlet

Orvlet is a native macOS side-screen assistant. A task keeps its state, controls,
conversation and source across compact and expanded views. Contributions should
preserve that continuity and the calm Pearl & Ink visual language.

Read the [product contract](docs/architecture/product-contract.md) and
[architecture map](docs/architecture/README.md) before changing behavior.

## Build and run

Use a Mac with Xcode (including its command-line tools), Python 3, and a logged-in
desktop session. The project targets macOS 14. Open `Orvlet.xcodeproj`, select the
**Orvlet** scheme and **My Mac**, or build from the repository root:

```sh
./scripts/build.sh Debug
open .build/Build/Products/Debug/Orvlet.app
```

No model credentials or signing account are required to compile or run local
fixture checks. Configure your own provider in **Settings → Models** for real
requests. Review access in **Settings → Access**. The project uses Xcode's
filesystem-synchronized groups; Swift files added under `Orvlet/` or
`Tests/AppChecks/` are picked up automatically.

`./scripts/build.sh Release` creates `dist/Orvlet.app`, scans it for accidental
credentials, and signs it locally. It uses `ORVLET_SIGNING_IDENTITY` when supplied,
the sole eligible installed identity otherwise, or ad-hoc signing. This is a local
build, not a notarized public distribution.

## Work on a change

1. Choose the owning feature folder from the architecture map. Keep business
   behavior out of view bodies and startup code. Runtime and data services accept
   narrow dependencies; adapters at the composition root own application state. Avoid adding task-specific
   keyword branches where a capability or typed intent can express the behavior.
2. Preserve stored schemas and migration readers. Renaming a Swift type is not a
   reason to change saved JSON keys, preference keys, task IDs or tool wire names.
3. Use existing task ownership, revision, verification and cancellation boundaries.
   A late response must not replace a newer edit or resurrect a closed task.
4. Keep primary controls direct and permanent chrome sparse. Use
   `Orvlet/Presentation/CalmVisualStyle.swift` for native and generated UI.
5. Format changed Swift files with `xcrun swift-format format --in-place <files>`.
   The root `.swift-format` defines the shared style; `scripts/format.sh` formats
   the complete source and native checks.

## Validate the behavior

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/check.py
# With a current Debug build, select affected suites:
python3 scripts/check.py --skip-build consistency side-screen
# For changes crossing the application boundaries:
python3 scripts/check.py --skip-build --full
```

For runtime/data boundary changes, `./scripts/check-services.sh` also type-checks
those services without application, agent, browser or view source files. This
quick architectural check does not launch the app or call a provider.

The default native run covers core behavior; the full run covers each distinct
suite once. Reports stay under `.local/checks/`. These checks operate native
windows and WebKit, so use a desktop session outside a restricted coding sandbox.
See [check ownership](docs/architecture/checks.md) before adding a check; avoid
repeating a shared group in another umbrella suite.

Inspect actual rendered UI and interactions for visual changes. A clean build
cannot establish layout quality or that a public service worked. Debug live
checks explicitly require `--allow-live-services`; they use the configured
provider and may incur charges or perform the actions named by that check.
Do not run them against private tasks or personal data as fixtures. Report what
was tested and what still depends on real-provider acceptance.

## Privacy and pull requests

- Keep keys in the application's private local credential store. Never put real
  keys, exported user sessions, pairing codes, screenshots of private data, or
  signing material in the repository or app resources. `.gitignore` is only one
  layer; source, staged/history and bundle scans protect different boundaries.
- Use synthetic fixture values. Test failures must not print credential values.
- Before a commit, run `python3 scripts/credential_check.py --staged`; before
  publication, run `python3 scripts/repository_check.py` on the prepared index.
  The publication check intentionally rejects unstaged changes to tracked files.
- Describe the user-visible problem, resulting behavior, compatibility impact,
  and relevant verification. Include actual rendered evidence for UI changes.
  Avoid bundling unrelated cleanup with a small behavioral fix.

Browser and MCP adapters live in `integrations/`. Browser script changes must
update both the app resource and adapter copy; the portable tests enforce parity.
