# Focused checks

`python3 scripts/check.py` builds once and runs the core self and consistency suites. `--skip-build` uses an existing Debug build. Repeated suite names run once. `--full` runs every distinct suite; explicit suite names select only the affected areas. Native builds/checks need a logged-in macOS desktop and run outside the restricted environment.

Each shared group has one suite owner: consistency owns task lifecycle/routing, motion owns motion, side-screen owns rendered layout/interactions. Do not invoke the same group from multiple umbrella suites. Keep distinct negative cases that protect ownership, external side effects or current data.

For a change, choose the smallest relevant suites, then broaden only for shared behavior or unresolved failures. UI changes additionally require rendered inspection. Live model checks are opt-in and measure real service behavior; they do not replace deterministic correctness checks. Credential scans remain in source/bundle/publication flows because each checks a different artifact boundary.

Generated tool verification follows the same rule: running an initializer or changed-input check already parses that handler; syntax checks apply to the remaining code. Identical action checks execute once. Do not replace meaningful changed-input behavior checks with tests that only echo initial values.

`ServiceBoundaryCheck` belongs to consistency. It exercises the runtime with an
in-memory store and the data service with an injected fetch/clock, without
constructing an application model. Keep adapter and rendered UI acceptance in
their existing suites. Obsolete projections used only by old checks are removed
with those assertions; retained migration readers still need compatibility checks.

The live delivery runner supports `--clock-only` for clock creation and timezone
correction. Use it for changes confined to time sources rather than repeating
calculator, stopwatch and counter acceptance. `--restore` checks saved execution
in a new process. All live modes retain the explicit service opt-in.

`model-api` owns local protocol transport checks: Chat Completions, Responses and Messages, multi-round tools, reasoning continuity, configuration overrides and redacted provider errors. It uses only the local fixture and synthetic credentials.
