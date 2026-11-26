#if DEBUG
    import AppKit
    import SwiftUI
    import WebKit

    /// The person may switch desktop apps during a background check. Record any activation of Orvlet itself.
    @MainActor
    final class BackgroundFocusCheck: NSObject {
        private(set) var tookFocus = false

        override init() {
            super.init()
            tookFocus = NSApp.isActive
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                   name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }

        @objc private func becameActive(_ notification: Notification) { tookFocus = true }
    }

    @MainActor
    enum StateMachineCheck {
        static func start() async {
            var checks: [String] = []
            let remindersOnly = CommandLine.arguments.contains("--card-reminders-only")
            if CommandLine.arguments.contains("--probe-reminder-policy") {
                guard CommandLine.arguments.contains("--allow-live-services") else {
                    fputs("The reminder policy probe needs --allow-live-services.\n", stderr)
                    exit(2)
                }
                do {
                    try await ModelPolicyProbe.checkReminderDelivery()
                    exit(0)
                } catch {
                    fputs(error.localizedDescription + "\n", stderr)
                    exit(1)
                }
            }
            let report = URL(fileURLWithPath: remindersOnly ? "/tmp/orvlet-card-reminders-checks.json" : "/tmp/orvlet-state-machine-checks.json")
            do {
                try require(
                    NSApplication.shared.windows.allSatisfy { !$0.isVisible },
                    "Background checks start before any app window is created", &checks)
                if !remindersOnly { checks += try await BuiltinCardsCheck.background() }
                checks += try await CardReminderCheck.run()
                checks += try await RuntimeLifecycleCheck.deadlineReminderChecks()
                if remindersOnly {
                    try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: report)
                    exit(0)
                }
                checks += try await playbackRecoveryChecks()
                checks += try SavedMusicPlayerCheck.run()
                checks += try await stateChecks()
                checks += try journalRecoveryChecks()
                checks += try await DecisionAPICheck.render()
                checks += try await LocalCredentialsCheck.run()
                checks += try await ModelProfileRecoveryCheck.run()
                checks += try await DetailViewportCheck.run()
                checks += try await WindowDragCheck.run()
                try await TaskDismissalCheck.run()
                checks += try await CapsuleMotionCheck.run()
                checks += try await PlaybackActivityCheck.run()
                checks += try await MusicRequestCheck.routingChecks()
                if #available(macOS 15.4, *) { checks += try await extensionChecks() }
                try require(
                    NSApplication.shared.windows.allSatisfy { !$0.isVisible },
                    "Offscreen render checks leave no visible windows", &checks)
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(
                    to: report)
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: [
                    "ok": false, "checks": checks, "error": error.localizedDescription,
                ]).write(to: report)
                exit(1)
            }
        }
        static func require(_ value: Bool, _ label: String, _ checks: inout [String]) throws {
            guard value else { throw AppError.message(label) }
            checks.append(label)
            print("PASS " + label)
        }
        static func journalRecoveryChecks() throws -> [String] {
            var checks: [String] = []
            let suite = "orvlet-journal-check-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let repo = WorkRepository(defaults: defaults)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
            let evening = calendar.date(from: DateComponents(year: 2030, month: 7, day: 1, hour: 23, minute: 59))!
            let midnight = evening.addingTimeInterval(60)
            for scope in [ActionJournalSpec.Scope.day, .allTime] {
                let id = repo.retain(title: "Print proofs", values: ["count": "10"],
                    definition: WorkDefinition(journal: .init(valueKey: "count", scope: scope)),
                    design: WorkDesign(), goalID: nil)
                guard let initial = repo.artifact(id) else { throw AppError.message("Journal was not saved") }
                try require(initial.values["count"] == "10" && initial.journalHistory?.entries.isEmpty == true,
                    "A starting count never invents earlier events", &checks)
                _ = repo.update(id, expecting: initial.revision) { item in
                    item.journalHistory = JournalHistory(day: evening)
                    item.values["count"] = "11"
                    item.recordJournal(from: "10", at: evening)
                    item.recordJournal(from: "11", at: evening)
                }
                guard var restored = WorkRepository(defaults: defaults).artifact(id) else {
                    throw AppError.message("Journal could not reopen")
                }
                try require(restored.values["count"] == "11" && restored.journalHistory?.entries.count == 1 &&
                    restored.journalHistory?.entries.first?.at == evening,
                    "Reopening preserves the actual click time and ignores a no-op", &checks)
                let changed = restored.rollJournal(to: midnight, calendar: calendar)
                if scope == .day {
                    let undoChanged = restored.undoJournal(at: midnight, calendar: calendar)
                    try require(changed && !undoChanged && restored.values["count"] == "0" && restored.journalHistory?.entries.isEmpty == true,
                        "A daily journal starts empty at local midnight and cannot undo yesterday", &checks)
                } else {
                    let undoChanged = restored.undoJournal(at: midnight, calendar: calendar)
                    try require(!changed && undoChanged && restored.values["count"] == "10" && restored.journalHistory?.entries.isEmpty == true,
                        "A running journal keeps its count overnight and undoes the exact last click", &checks)
                }
            }
            return checks
        }
        static func playbackRecoveryChecks() async throws -> [String] {
            let suite = "orvlet-playback-recovery-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let memory = PlaybackSourceMemory(defaults)
            let bad = MusicTrack(id: "original123", title: "Recording", searchQuery: "Recording studio", styleSelection: false)
            let good = MusicTrack(id: "fallback123", title: "Recording")
            var checks: [String] = []
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
            view.loadHTMLString("<video></video><div id='movie_player'><div class='ytp-error-content'>fixture</div></div>",
                baseURL: URL(string: bad.url))
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("!!document.querySelector('.ytp-error-content')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await view.evaluateJavaScript(BrowserController.script)
            let failed = try await view.evaluateJavaScript("window.__orvlet.state().playbackFailed") as? Bool == true
            try require(failed, "The visible player error is detected even without a native media error or translated text", &checks)
            _ = try await view.evaluateJavaScript("document.querySelector('.ytp-error-content').remove();true")
            try require(try await view.evaluateJavaScript("window.__orvlet.state().playbackFailed") as? Bool == false,
                "A paused or buffering media element does not mark its source as broken", &checks)
            var visits: [String] = []
            try await memory.play(bad, replacement: { _ in good }, attempt: { track in
                visits.append(track.id)
                if track.id == bad.id && failed { throw PlaybackSourceUnavailable() }
            })
            try require(visits == [bad.id, good.id], "A confirmed failure switches to a matching alternative in the same operation", &checks)
            var style = bad
            style.searchQuery = "ambient instrumentals"
            style.styleSelection = true
            var nextStyle = good
            nextStyle.searchQuery = style.searchQuery
            nextStyle.styleSelection = true
            let queue = MusicQueue(upcoming: [good, nextStyle])
            try require(queue.matchingReplacement(for: style, available: { !memory.avoids($0.url) }) == nextStyle &&
                queue.matchingReplacement(for: bad, available: { _ in true }) == nil,
                "Only another track selected for the same style can replace a failed source directly from the queue", &checks)
            let restarted = PlaybackSourceMemory(defaults)
            visits = []
            try await restarted.play(bad, replacement: { _ in throw MusicSelectionUnavailable() }, attempt: { visits.append($0.id) })
            try require(visits == [good.id] && restarted.avoids("https://youtu.be/" + bad.id + "?t=3") && !restarted.avoids(good.url),
                "A later session skips the failed video and its URL aliases before navigation", &checks)
            try require(restarted.preferredSong("  RECORDING   studio ")?.id == good.id &&
                restarted.preferredSong("Recording live") == nil, "Repeat song requests reuse verified playback and preserve version qualifiers", &checks)
            let migrationSuite = suite + "-migration"
            let migration = UserDefaults(suiteName: migrationSuite)!
            defer { migration.removePersistentDomain(forName: migrationSuite) }
            migration.set([PlaybackSourceMemory.identity(bad.url)!: 1.0], forKey: "mediaSourceCooldowns.v1")
            let migrated = PlaybackSourceMemory(migration)
            try require(migrated.avoids(bad.url) && PlaybackSourceMemory(migration).avoids(bad.url),
                "An old expired cooldown migrates to a lasting failure and survives restart", &checks)
            do {
                try await restarted.play(good, replacement: { _ in bad }, attempt: { _ in throw CancellationError() })
            } catch is CancellationError {}
            try require(!restarted.avoids(good.url), "Cancellation does not blacklist a healthy source", &checks)
            var attempts = 0
            do {
                try await restarted.play(good, replacement: { _ in
                    MusicTrack(id: attempts == 1 ? "another0123" : "another0456", title: "Recording")
                }, attempt: { _ in attempts += 1; throw PlaybackSourceUnavailable() })
            } catch is PlaybackSourceUnavailable {}
            try require(attempts == 3, "An exhausted set of sources stops after three attempts", &checks)
            let third = MusicTrack(id: "working0123", title: "Recording")
            visits = []
            try await restarted.play(bad, replacement: { _ in third }, attempt: { visits.append($0.id) })
            try require(visits == [third.id] && PlaybackSourceMemory(defaults).preferredSong("Recording studio")?.id == third.id,
                "A failed replacement stays excluded and verified playback updates the next song request", &checks)
            let generic = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
            generic.loadHTMLString("<video preload='none'></video>", baseURL: URL(string: "https://example.invalid/recording"))
            for _ in 0..<100 {
                if (try? await generic.evaluateJavaScript("!!document.querySelector('video')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await generic.evaluateJavaScript(BrowserController.script)
            let switched = try await generic.evaluateJavaScript("""
                (() => {
                  const video = document.querySelector('video');
                  for (const name of ['first','second']) {
                    const option = document.createElement('source');
                    option.src = 'https://example.invalid/' + name;
                    video.appendChild(option);
                  }
                  Object.defineProperty(video, 'currentSrc', {value:'https://example.invalid/first'});
                  Object.defineProperty(video, 'error', {value:{code:2}, configurable:true});
                  if (window.__orvlet.state().playbackFailed) return false;
                  Object.defineProperty(video, 'error', {value:{code:3}});
                  Object.defineProperty(video, 'play', {value:() => Promise.resolve()});
                  const state = window.__orvlet.state();
                  const next = state.alternativeMediaSources[1];
                  return state.playbackFailed && window.__orvlet.replaceMediaSource(location.href, state.activeMediaSource, next) && video.src === next;
                })()
                """)
            try require(switched as? Bool == true, "A standard HTML player can switch to another declared encoding after a decoder error", &checks)
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            let restored = try await model.savedPlaybackReplacement(bad.url, title: bad.title, task: nil)
            try require(restored?.selected.id == third.id, "Restoring a failed saved video resolves directly to its verified replacement", &checks)
            let browser = BrowserController(model: model)
            defer { browser.dispose() }
            var observed: [String: Any] = ["url": bad.url, "playing": true, "currentTime": 1.0]
            browser.updateState(observed)
            browser.updateState(observed)
            try require(model.playbackSources.avoids(bad.url), "Opening a failed video without progress keeps its failure record", &checks)
            observed["currentTime"] = 2.0
            browser.updateState(observed)
            try require(!PlaybackSourceMemory(defaults).avoids(bad.url), "Observed playback progress on a manually opened page clears its failure", &checks)
            let a = "https://example.invalid/a", b = "https://example.invalid/b", c = "https://example.invalid/c"
            let catalog = "https://example.invalid/library"
            model.playbackSources.recordPlayerFailure(["url": catalog, "activeMediaSource": a, "playbackFailed": true])
            try require(model.playbackSources.avoids(a) && !model.playbackSources.avoids(catalog),
                "A failed media file leaves its shared library page eligible", &checks)
            model.playbackSources.verifiedMedia(b, replacing: a)
            try require(PlaybackSourceMemory(defaults).preferredMedia(for: a, among: [c, b]) == b,
                "A previously verified media encoding takes priority over an untested alternative", &checks)
            model.playbackSources.record(b)
            try require(model.playbackSources.preferredMedia(for: a, among: [b, c]) == nil, "A broken alternate encoding loses priority", &checks)
            model.playbackSources.verifiedMedia(c, replacing: b)
            try require(PlaybackSourceMemory(defaults).preferredMedia(for: a, among: [a, b, c]) == c,
                "The first failed encoding resolves to its latest verified successor after restart", &checks)
            return checks
        }

        static func stateChecks() async throws -> [String] {
            var checks: [String] = []
            let suite = "orvlet-state-audit-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.settings.autoAdapt = false
            model.persistHistory = false
            let browser = model.browser
            defer {
                browser.dispose()
                model.taskRuntime.stopAll()
            }
            let first = browser.webView.loadHTMLString("<p>First</p>", baseURL: nil)!
            browser.webView(browser.webView, didStartProvisionalNavigation: first)
            let second = browser.webView.loadHTMLString("<p>Second</p>", baseURL: nil)!
            browser.webView(browser.webView, didStartProvisionalNavigation: second)
            browser.webView(browser.webView, didFailProvisionalNavigation: first, withError: URLError(.cancelled))
            try require(
                browser.loading && model.webLoading,
                "An old cancelled navigation cannot clear the new navigation's loading state", &checks)
            browser.webView(browser.webView, didFinish: first)
            try require(browser.loading, "An old finish callback cannot commit a newer document", &checks)
            browser.webViewWebContentProcessDidTerminate(browser.webView)
            try require(
                !browser.loading && !model.webLoading && !model.isPlaying && model.webError != nil,
                "A terminated web process exits loading/playback and exposes recovery", &checks)
            browser.dispose()
            browser.webView(browser.webView, didStartProvisionalNavigation: second)
            try require(!browser.loading, "Disposed browsers ignore callbacks and repeated disposal", &checks)
            browser.dispose()

            let timerID = try model.startTimer(seconds: 60)
            let deadline = model.sideTasks.first { $0.id == timerID }?.deadline
            model.timerAction(timerID, action: "unknown")
            try require(
                model.sideTasks.first { $0.id == timerID }?.deadline == deadline,
                "Unknown timer controls cannot toggle a running countdown", &checks)
            model.timerAction(timerID, action: "stop")
            model.timerAction(timerID, action: "addMinute")
            try require(
                model.sideTasks.first { $0.id == timerID }?.finished == true,
                "Adding time cannot silently restart a completed timer", &checks)

            let elapsedID = UUID()
            let elapsed = try TaskSurface(
                title: "Elapsed",
                markup: CardMarkup(
                    html: "<span data-bind='value'></span>", compactHTML: "<span data-bind='value'></span>", css: ""),
                fields: [], actions: [], state: [:],
                runtime: TaskRuntimeSpec(sources: [.init(key: "value", kind: .elapsed, format: .seconds)])
            ).validated()
            model.publishTaskSurface(elapsed, id: elapsedID)
            let elapsedResource = model.work.view(elapsedID)!.selected
            _ = try await model.endTask(elapsedID, action: .cancel)
            try require(
                model.work.artifact(elapsedResource)?.runtimeState?.pausedAt != nil,
                "Ending an elapsed task records its stop time so resume excludes the stopped interval", &checks)

            let repository = model.work
            let goal = UUID()
            let run = UUID()
            repository.begin(goalID: goal, runID: run, request: "Audit fixture")
            let interrupted = repository.retain(
                title: "Counter", values: ["value": "8"], definition: WorkDefinition(), design: WorkDesign(),
                goalID: goal)
            _ = repository.update(interrupted, expecting: repository.artifact(interrupted)!.revision) {
                $0.status = "Updating…"
            }
            let inspection = WorkRepository(defaults: defaults)
            try require(
                inspection.snapshot.goals[goal]?.status == .running,
                "Read-only repository inspection does not interrupt active work", &checks)
            let restarted = WorkRepository(defaults: defaults, recoverInterrupted: true)
            try require(
                restarted.snapshot.goals[goal]?.status == .partial && restarted.snapshot.attempts[run]?.finished != nil,
                "Restart ends interrupted requests without claiming successful completion", &checks)
            try require(
                restarted.artifact(interrupted)?.status == "Update unavailable"
                    && restarted.artifact(interrupted)?.values["value"] == "8",
                "Restart preserves the last verified value and clears a stranded Updating state", &checks)

            var waiters: [CheckedContinuation<[String: Any], Never>] = []
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { _ in
                    await withCheckedContinuation { waiters.append($0) }
                })
            let spec = APIDataSpec(
                url: "https://example.org/audit", fields: [.init(key: "count", label: "Count", pointer: "/count")],
                card: .init(kind: .reading, primaryKey: "count", subject: "Audit"))
            let id = model.retainWorkResult(
                title: "Audit", values: ["count": "0", "resultStatus": "", "sourceHost": "example.org"], spec: spec)
            let action = try model.workSurface(repository.artifact(id)!).actions.first { $0.operation == "refresh" }!.id
            let old = model.performWorkOperation(id, action: action, fields: [:])!
            for _ in 0..<100 where waiters.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
            guard waiters.count == 1 else { throw AppError.message("First fixture read did not start") }
            let next = model.performWorkOperation(id, action: action, fields: [:])!
            for _ in 0..<100 where waiters.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
            guard waiters.count == 2 else {
                waiters[0].resume(returning: ["count": 1])
                throw AppError.message("Second fixture read did not start")
            }
            waiters[0].resume(returning: ["count": 1])
            await old.value
            try require(
                model.workJobs[id] != nil && repository.artifact(id)?.values["count"] == "0",
                "Cancelled old completion cannot clear a replacement job or overwrite its result", &checks)
            waiters[1].resume(returning: ["count": 2])
            await next.value
            try require(
                model.workJobs[id] == nil && model.workJobTokens[id] == nil
                    && repository.artifact(id)?.values["count"] == "2",
                "Only the current operation commits and releases its job slot", &checks)
            return checks
        }
        @available(macOS 15.4, *)
        static func extensionChecks() async throws -> [String] {
            var checks: [String] = []
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "orvlet-extension-check-" + UUID().uuidString)
            let source = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let manifest: [String: Any] = [
                "manifest_version": 3, "name": "Reading helper", "version": "1.0",
                "description": "Local extension regression fixture",
                "permissions": ["storage", "declarativeNetRequest"], "host_permissions": ["http://127.0.0.1/*"],
                "content_scripts": [
                    ["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"]
                ],
                "action": ["default_popup": "popup.html"],
                "declarative_net_request": [
                    "rule_resources": [["id": "rules", "enabled": true, "path": "rules.json"]]
                ],
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(
                to: source.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.extensionCheck='active';".utf8).write(
                to: source.appendingPathComponent("content.js"))
            try Data("<html><body>Reading helper</body></html>".utf8).write(
                to: source.appendingPathComponent("popup.html"))
            try Data(
                "[{\"id\":1,\"priority\":1,\"action\":{\"type\":\"block\"},\"condition\":{\"urlFilter\":\"extension-blocked\",\"resourceTypes\":[\"xmlhttprequest\"]}}]"
                    .utf8
            ).write(to: source.appendingPathComponent("rules.json"))
            let host = BrowserExtensions(root: base.appendingPathComponent("installed"), persistent: false)
            await host.ready()
            try await host.prepareImport(source)
            try require(
                host.pending != nil && host.contexts.isEmpty && host.entries.isEmpty,
                "Import reviews requested permissions before executing any extension", &checks)
            host.cancelImport()
            try require(
                host.pending == nil && host.entries.isEmpty, "Cancelling import leaves no installed extension", &checks)
            try await host.prepareImport(source)
            try host.approveImport()
            let id = host.entries[0].id
            try require(
                host.contexts[id]?.isLoaded == true, "Approved extension loads through WebKit's native runtime", &checks
            )
            var rejected = false
            do { try await host.prepareImport(source) } catch { rejected = true }
            try require(
                rejected && host.entries.count == 1, "Repeated import cannot create duplicate extensions", &checks)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            host.configure(config)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
            host.register(web)
            defer {
                host.unregister(web)
                web.stopLoading()
            }
            func loadAndRead() async throws -> String {
                web.load(
                    URLRequest(url: URL(string: "http://127.0.0.1:19244/fixture?extension-test=\(UUID().uuidString)")!))
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(50))
                    if !web.isLoading, web.url != nil {
                        try await Task.sleep(for: .milliseconds(150))
                        return try await web.evaluateJavaScript("document.documentElement.dataset.extensionCheck || ''")
                            as? String ?? ""
                    }
                }
                throw AppError.message("Extension fixture failed to load")
            }
            try require(
                try await loadAndRead() == "active", "Imported Chrome content script runs on an allowed Orvlet page",
                &checks)
            let blocked =
                try await web.callAsyncJavaScript(
                    "try { await fetch('/fixture?extension-blocked'); return false; } catch { return true; }",
                    arguments: [:], in: nil, contentWorld: .page) as? Bool
            try require(blocked == true, "Manifest V3 declarative network rule actually blocks a request", &checks)
            try await host.setEnabled(id, false)
            try require(
                try await loadAndRead() == "", "Disabling removes content-script injection from subsequent documents",
                &checks)
            let unblocked =
                try await web.callAsyncJavaScript(
                    "try { await fetch('/fixture?extension-blocked'); return true; } catch { return false; }",
                    arguments: [:], in: nil, contentWorld: .page) as? Bool
            try require(unblocked == true, "Disabling unloads network rules as well as scripts", &checks)
            try await host.setEnabled(id, true)
            try require(
                try await loadAndRead() == "active", "Re-enabling restores scripts after a fresh navigation", &checks)
            let restored = BrowserExtensions(root: host.root, persistent: false)
            await restored.ready()
            try require(
                restored.contexts[id]?.isLoaded == true,
                "Restart restores enabled extensions with their stable identity", &checks)
            try await restored.setEnabled(id, false)
            try await host.setEnabled(id, false)
            try Data("// modified".utf8).write(
                to: host.root.appendingPathComponent(id.uuidString).appendingPathComponent("content.js"))
            rejected = false
            do { try await host.setEnabled(id, true) } catch { rejected = true }
            try require(
                rejected && host.contexts[id] == nil, "Changed extension files cannot acquire permissions silently",
                &checks)
            try await host.remove(id)
            try require(
                host.entries.isEmpty && host.contexts.isEmpty,
                "Remove deletes the installed package and its registration", &checks)
            try FileManager.default.createSymbolicLink(
                at: source.appendingPathComponent("link.js"),
                withDestinationURL: source.appendingPathComponent("content.js"))
            rejected = false
            do { try await host.prepareImport(source) } catch { rejected = true }
            try require(rejected, "Imported folders reject symbolic links", &checks)
            try FileManager.default.removeItem(at: source.appendingPathComponent("link.js"))
            try await host.prepareImport(source)
            try host.approveImport()
            let zip = base.appendingPathComponent("fixture.zip")
            let archive = Process()
            archive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            archive.arguments = ["-c", "-k", source.path, zip.path]
            try archive.run()
            archive.waitUntilExit()
            guard archive.terminationStatus == 0 else { throw AppError.message("Could not create ZIP fixture") }
            try await host.prepareImport(zip)
            try host.approveImport()
            let zipID = host.entries.last!.id
            try require(
                host.entries.last?.archive == true && host.contexts[zipID]?.isLoaded == true,
                "Extension ZIP packages load directly through WebKit", &checks)
            try await host.setEnabled(zipID, false)
            let disabledRestart = BrowserExtensions(root: host.root, persistent: false)
            await disabledRestart.ready()
            try require(
                disabledRestart.contexts[zipID] == nil
                    && disabledRestart.entries.contains { $0.id == zipID && !$0.enabled },
                "A disabled extension remains disabled after restart", &checks)
            for entry in disabledRestart.entries where entry.enabled {
                try await disabledRestart.setEnabled(entry.id, false)
            }
            // Render same-name, same-version instances at the production width; their content identities remain visible.
            // Render at the production settings width without taking desktop focus.
            for dark in [false, true] {
                let view = NSHostingView(
                    rootView: BrowserExtensionSettings(host: host, web: web)
                        .controlSize(.small).tint(AppSettings().theme.color)
                        .padding(20).frame(width: 470)
                        .background(
                            dark ? Color(red: 0.14, green: 0.135, blue: 0.18) : Color(red: 0.98, green: 0.975, blue: 1)
                        )
                        .preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(
                    contentRect: NSRect(x: -16000, y: -16000, width: 470, height: 235), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderBack(nil)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                try await SideScreenCheck.snapshot(
                    window, path: "/tmp/orvlet-extensions-\(dark ? "dark" : "light").png")
                window.orderOut(nil)
            }
            checks.append("Extension controls rendered at actual settings width in light and dark appearances")
            for entry in host.entries { try await host.remove(entry.id) }
            return checks
        }
    }
#endif
