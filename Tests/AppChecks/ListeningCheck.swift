#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum ListeningCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.main = Endpoint()
            model.settings.reduceMotion = true
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(450)) }
            do {
                checks += try await PlaybackRestartCheck.local(model)
                let source = model.browser
                let page = try await source.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture?listening",
                ])
                _ = try await source.action(["action": "media", "operation": "play"])
                let second = BrowserController(model: model)
                let secondWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                secondWindow.contentView = second.webView
                defer {
                    second.dispose()
                    secondWindow.orderOut(nil)
                }
                _ = try await second.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture?second-player",
                ])
                try check(
                    try await source.observe()["playing"] as? Bool == true && second.audioFocusHeld,
                    "Preparing another page preserves current playback and holds the new source")
                _ = try await second.action(["action": "media", "operation": "play"])
                try check(
                    try await source.observe()["playing"] as? Bool == false,
                    "The previous source is paused before a different player starts")
                try check(
                    try await second.observe()["playing"] as? Bool == true,
                    "The requested new player starts after exclusive ownership transfers")
                _ = try await source.webView.evaluateJavaScript(
                    "document.querySelector('audio').play().catch(()=>{});true")
                try await pause()
                try check(
                    try await source.observe()["playing"] as? Bool == false,
                    "An inactive player cannot resume itself through page autoplay")
                source.setUserPlaybackPaused(false)
                let resumeGeneration = source.playbackGeneration
                await source.applyPlaybackPolicy()
                try check(
                    source.playbackGeneration == resumeGeneration,
                    "Internal audio handoff does not invalidate the user's native resume command")
                _ = try await source.action(["action": "media", "operation": "play"])
                try check(
                    try await second.observe()["playing"] as? Bool == false
                        && model.playbackCoordinator.owner == source.id,
                    "Explicitly resuming an older player transfers audio ownership back")
                let cancelled = Task { try await model.playbackCoordinator.acquire(second) }
                cancelled.cancel()
                _ = try? await cancelled.value
                try check(
                    model.playbackCoordinator.owner == source.id,
                    "A cancelled ownership request cannot steal current audio")
                second.dispose()
                _ = try await source.webView.evaluateJavaScript(
                    "window.pauseCount=0;document.querySelector('audio').addEventListener('pause',()=>window.pauseCount++);const b=document.createElement('button');b.textContent='Pause (k)';b.onclick=()=>document.querySelector('audio').pause();document.body.append(b);true"
                )
                let beforeGuard = (try await source.observe())["currentTime"] as? Double ?? 0
                var blockedToggle = false
                do {
                    _ = try await source.action([
                        "action": "click", "name": "Pause (k)", "role": "button", "preservePlayback": true,
                    ])
                } catch { blockedToggle = true }
                _ = try await source.action(["action": "media", "operation": "play"])
                try await pause()
                let afterGuard = try await source.observe()
                try check(
                    blockedToggle && afterGuard["playing"] as? Bool == true
                        && (afterGuard["currentTime"] as? Double ?? 0) > beforeGuard,
                    "Agent toggle clicks are blocked while repeated play preserves advancing playback")
                try check(
                    try await source.webView.evaluateJavaScript("window.pauseCount") as? Int == 0,
                    "Playback protection never causes a transient pause and restart")
                _ = try await source.action(["action": "click", "name": "Pause (k)", "role": "button"])
                try check(
                    try await source.observe()["playing"] as? Bool == false,
                    "Explicit page controls can still pause playback")
                _ = try await source.action(["action": "media", "operation": "play"])
                _ = try await source.action(["action": "media", "operation": "seek", "value": 5])
                let loopStart = try await source.observe()
                _ = try await source.action(["action": "media", "operation": "loop"])
                _ = try await source.action(["action": "media", "operation": "loop"])
                try await pause()
                let looping = try await source.observe()
                try check(
                    looping["looping"] as? Bool == true && looping["playing"] as? Bool == true
                        && (looping["currentTime"] as? Double ?? 0) >= (loopStart["currentTime"] as? Double ?? 0),
                    "Enabling repeat twice preserves the current position and uninterrupted playback")
                _ = try await source.action(["action": "media", "operation": "unloop"])
                _ = try await source.webView.evaluateJavaScript(
                    "Object.defineProperty(document.querySelector('audio'),'duration',{get:()=>Infinity,configurable:true});true"
                )
                var loopUnavailable = false
                do { _ = try await source.action(["action": "media", "operation": "loop"]) } catch {
                    loopUnavailable = true
                }
                let unsupportedState = try await source.observe()
                try check(
                    loopUnavailable && unsupportedState["playing"] as? Bool == true,
                    "Unsupported live-stream repeat fails without stopping or restarting playback")
                _ = try await source.webView.evaluateJavaScript("delete document.querySelector('audio').duration;true")
                var plan = SurfacePlan(components: [], width: 300, height: 160, title: "Music")
                plan.markup = CardMarkup(
                    html:
                        "<h2 data-bind='title'></h2><small data-bind='status'></small><button data-action='next'>Next</button>",
                    compactHTML: "", css: "h2{font-size:16px}", height: 140)
                plan.actions = [
                    BoundCardAction(
                        id: "next", binding: PageBinding(action: "click", role: "button", name: "Next item"))
                ]
                model.install(try plan.validated(observation: page))
                model.hasCustomSurface = true
                model.upsertWebTask(model.surface, activate: true)
                try check(
                    model.selectedSideTask?.isMediaTask == false,
                    "Incidental page media is not a listening task without explicit intent")
                model.beginBackgroundListening()
                model.upsertWebTask(model.surface)
                model.settings.useFast = true
                model.agent.completionOverride = { _ in
                    throw AppError.message("Direct control unexpectedly called the execution model")
                }
                model.agent.interpretationOverride = { _ in
                    throw AppError.message("Direct control unexpectedly reinterpreted the request")
                }
                for control in ["pause", "resume", "loop", "unloop"] {
                    let text = "Synthetic " + control
                    let advice = RequestTriage(budget: .low, target: source.id, routeKnown: true, action: control)
                    let before = (try await source.observe())["currentTime"] as? Double ?? 0
                    let prepared = PreparedRequest(text: text, triage: advice, model: model)
                    _ = try await model.agent.run(text, taskID: source.id, prepared: prepared)
                    let after = try await source.observe()
                    try check(
                        (after["currentTime"] as? Double ?? 0) + 0.5 >= before,
                        "Fast " + control + " executes without a model call or playback reset")
                }
                model.agent.completionOverride = nil
                model.agent.interpretationOverride = nil
                model.settings.useFast = false
                model.collapse()
                model.toggleTaskPresentation(source.id)
                try await pause()
                try check(
                    !model.collapsed && !model.showingWeb && model.selectedSideTask?.listening == true,
                    "Opening a listening task displays the player card rather than its webpage")
                var guarded = plan
                guarded.actions?.append(
                    BoundCardAction(
                        id: "pause", binding: PageBinding(action: "media", operation: "pause"), revealSource: true))
                model.install(try guarded.validated(observation: try await source.observe()))
                model.upsertWebTask(model.surface)
                model.cardAction(source.id, action: "pause", value: nil)
                try await pause()
                let paused =
                    try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool
                    == true
                try check(
                    !model.showingWeb && paused,
                    "A generated media action cannot reveal the source even if its layout requests it")
                var refused = false
                do { _ = try await source.action(["action": "media", "operation": "play"]) } catch { refused = true }
                try check(
                    refused && source.userPausedPlayback,
                    "A generated pause cannot be overridden by a later background play action")
                _ = try await source.webView.evaluateJavaScript(
                    "document.querySelector('audio').play().catch(()=>{});true")
                try await pause()
                try check(
                    try await source.observe()["playing"] as? Bool == false,
                    "Page autoplay cannot resume media after a direct user pause")
                model.controlMedia(source.id, operation: "play")
                try await pause()
                let resumed = try await source.observe()
                try check(
                    !source.userPausedPlayback && resumed["playing"] as? Bool == true,
                    "Only explicit user play clears the pause hold")
                model.collapse()
                model.reveal(preview: true)
                try check(!model.showingWeb, "Hover preview cannot replace a listening card with the source webpage")
                model.cardAction(source.id, action: "source", value: nil)
                try await pause()
                try check(
                    model.showingWeb && model.browser === source,
                    "Explicit source action still reveals the same live webpage")
                model.collapse()
                let webIdentity = source.webView
                _ = try await source.webView.evaluateJavaScript(
                    "window.savedAudio=document.querySelector('audio');window.savedAudio.remove();history.pushState({},'', '/fixture?next-track')"
                )
                source.updateState(try await source.observe())
                try check(
                    model.selectedSideTask?.isMediaTask == true && model.selectedSideTask?.hasMedia == false
                        && model.selectedSideTask?.status == "Loading…",
                    "Player replacement and playlist URL changes retain the listening card with loading status")
                try check(
                    model.collapsed && !model.showingWeb && source.webView === webIdentity,
                    "Transient media loss never expands or replaces the source context")
                let saved = try JSONDecoder().decode(SideTask.self, from: JSONEncoder().encode(model.selectedSideTask!))
                try check(
                    saved.listening == true && saved.isMediaTask,
                    "Listening intent persists even when saved between tracks")
                _ = try await source.webView.evaluateJavaScript("document.body.append(window.savedAudio)")
                _ = try await source.action(["action": "media", "operation": "play"])
                source.updateState(try await source.observe())
                model.controlMedia(source.id, operation: "pause")
                try await pause()
                try check(
                    try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool
                        == true, "Native pause remains available after the player is replaced")
                model.controlMedia(source.id, operation: "play")
                try await pause()
                let start = (try await source.observe())["currentTime"] as? Double ?? 0
                model.buildingSurface = true
                model.recordTaskOutcome(source.id, .interfaceFailed)
                try await Task.sleep(for: .milliseconds(1200))
                let continued = try await source.observe()
                model.buildingSurface = false
                try check(
                    continued["playing"] as? Bool == true && (continued["currentTime"] as? Double ?? 0) > start,
                    "UI preparation or failure never interrupts an already running task")
                try model.prepareBrowserForNewTask()
                _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/live-reading"])
                model.upsertWebTask(activate: true)
                try check(
                    model.sideTasks.first(where: { $0.id == model.browser.id })?.isMediaTask == false,
                    "A new clock page with incidental audio does not inherit the music role")
                _ = try await source.webView.evaluateJavaScript("document.querySelector('audio').style.display='none'")
                source.updateState(try await source.observe())
                try check(
                    model.quickMediaTasks.contains(where: { $0.id == source.id }),
                    "A parked listening task retains controls when its underlying media becomes visually hidden")
                let clockID = model.browser.id
                var navigationPlan = plan
                navigationPlan.actions?[0].revealSource = true
                if let i = model.sideTasks.firstIndex(where: { $0.id == source.id }) {
                    model.sideTasks[i].plan = navigationPlan
                }
                model.selectTask(source.id, expanded: true)
                model.cardAction(source.id, action: "next", value: nil)
                model.selectTask(clockID, expanded: true)
                try await pause()
                try check(
                    model.selectedTaskID == clockID,
                    "A pending webpage action cannot steal the expanded view after the user selects another task")
                model.selectTask(source.id, expanded: true)
                try await pause()
                try check(
                    !model.showingWeb && source.webView === webIdentity,
                    "Returning from another task opens the retained music card without reloading")
                model.controlMedia(source.id, operation: "pause")
                try await pause()
                try check(
                    try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool
                        == true, "Background music controls still target the owning player")
                var watching = saved
                watching.listening = false
                watching.prefersSource = true
                try check(
                    watching.opensSourceByDefault, "An explicitly watching task can still prefer the video webpage")
                var changed = saved
                changed.updateMediaRole(primary: false, url: "https://example.org/clock")
                changed.hasMedia = true
                try check(
                    !changed.isMediaTask && changed.listening == false && changed.opensSourceByDefault,
                    "An unrelated origin does not inherit the listening role")
                model.selectTask(clockID, expanded: true)
                try check(model.showingWeb, "Non-media tasks retain their direct source interaction")
                let held = BrowserController(model: model)
                model.parkedBrowsers[held.id] = held
                model.browserRevision += 1
                try await pause()
                held.waitForInterface()
                await held.applyPlaybackPolicy()
                _ = try await held.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture?interface-first",
                ])
                let deferred = try await held.action(["action": "media", "operation": "play"])
                try check(
                    deferred["playbackDeferred"] as? Bool == true && deferred["playing"] as? Bool != true,
                    "Interface-first holds playback while preparing controls")
                held.releaseInterface()
                await held.applyPlaybackPolicy()
                _ = try await held.action(["action": "media", "operation": "play"])
                try await pause()
                try check(
                    try await held.observe()["playing"] as? Bool == true,
                    "Playback can start after the interface hold is released")
                held.waitForInterface()
                held.setUserPlaybackPaused(true)
                held.releaseInterface()
                await held.applyPlaybackPolicy()
                try check(held.playbackSuspended, "Completing an interface cannot undo a newer user pause")
                held.dispose()
                // A generated, fully bound transport survives track changes without a model call.
                try model.activateTaskSource(source.id)
                _ = try await source.webView.evaluateJavaScript(
                    "document.querySelector('audio').style.display='block';true")
                var reusable = SurfacePlan(components: [], width: 300, height: 150, title: "Old song")
                reusable.markup = CardMarkup(
                    html: "<h2 data-bind='title'></h2><button data-action='play' data-bind='toggleLabel'></button>",
                    compactHTML: "", css: "h2{font-size:18px}", height: 130)
                reusable.actions = [
                    BoundCardAction(id: "play", binding: PageBinding(action: "media", operation: "toggle"))
                ]
                model.install(try reusable.validated(observation: try await source.observe()))
                model.hasCustomSurface = true
                model.beginBackgroundListening()
                model.upsertWebTask(model.surface)
                model.settings.autoAdapt = true
                model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
                var compositions = 0
                model.adaptive.compositionOverride = { _ in
                    compositions += 1
                    return reusable
                }
                model.controlMedia(source.id, operation: "play")
                try await pause()
                _ = try await source.webView.evaluateJavaScript(
                    "document.title='New song';history.pushState({},'', '/fixture?track=two');true")
                source.updateState(try await source.observe())
                try await Task.sleep(for: .milliseconds(1000))
                try check(
                    compositions == 0 && model.surface.markup == reusable.markup && model.hasCustomSurface
                        && model.trackTitle == "New song",
                    "Changing a track URL retains the generated transport and refreshes its live title without composition"
                )
                _ = try await source.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture?track=full-navigation",
                ])
                try await Task.sleep(for: .milliseconds(1000))
                try check(
                    compositions == 0 && model.surface.markup == reusable.markup,
                    "Full page navigation to another track also reuses the player after live validation")
                var otherSource = try await source.observe()
                otherSource["url"] = "https://other.example/fixture?track=two"
                try check(
                    source.reusableMediaSurface(otherSource) == nil, "Another origin cannot inherit the player layout")
                otherSource["url"] = "http://127.0.0.1:19244/article"
                try check(
                    source.reusableMediaSurface(otherSource) == nil,
                    "A different page type cannot inherit a player layout")
                var frozen = reusable
                frozen.markup?.html += "<p>Old artist name</p>"
                try check(!frozen.reusableTransport, "Static track facts disqualify cross-track layout reuse")
                frozen = reusable
                frozen.readings = [CardReading(key: "lyrics", selector: "#lyrics")]
                try check(!frozen.reusableTransport, "Source-specific readings retain exact content identity")
                try check(
                    SurfaceCache.pageKey("https://example.org/watch?v=one")
                        != SurfaceCache.pageKey("https://example.org/watch?v=two"),
                    "Exact content cache keys remain distinct")
                try model.activateTaskSource(clockID)
                _ = try await source.webView.evaluateJavaScript(
                    "document.title='Background song';history.pushState({},'', '/fixture?track=three');true")
                source.updateState(try await source.observe())
                try check(
                    model.sideTasks.first(where: { $0.id == source.id })?.plan?.markup == reusable.markup
                        && model.sideTasks.first(where: { $0.id == source.id })?.title == "Background song",
                    "Background track changes retain controls and refresh content too")
                try model.activateTaskSource(source.id)
                model.adaptive.suspendAutomaticUpdates(source.id)
                model.hasCustomSurface = false
                model.surface = .webpage
                model.adaptive.changed()
                try await Task.sleep(for: .milliseconds(1000))
                try check(
                    compositions == 0 && !model.buildingSurface,
                    "Failed or stopped tasks do not silently restart automatic interface generation")
                model.beginAmbientRequest("Continue", taskID: source.id)
                try check(
                    !model.adaptive.blockedSources.contains(source.id),
                    "An explicit retry re-enables automatic updates for its owner")
                model.finishAmbientRequest()
                model.adaptive.changed()
                try await Task.sleep(for: .milliseconds(1000))
                model.selectTask(source.id, expanded: true)
                try await pause()
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-reused-player.png")
                model.pinned = true
                model.adaptive.changed(force: true)
                try await Task.sleep(for: .milliseconds(800))
                try check(
                    compositions == 0 && !model.buildingSurface,
                    "A pinned view does not spend a model call on a discarded automatic redesign")
                model.pinned = false
                model.adaptive.compositionOverride = nil
                try JSONSerialization.data(
                    withJSONObject: [
                        "ok": true, "checks": checks,
                        "scope": "Local real WebKit playback and DOM/URL transition fixtures; no live YouTube ad claim",
                    ], options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-listening-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-listening-checks.json"))
                exit(1)
            }
        }
    }
#endif
