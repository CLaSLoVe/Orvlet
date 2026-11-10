#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum SelfCheck {
        static func run(model: AppModel) async {
            var checks: [String] = []
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw AppError.message("Check failed: " + name) }
                checks.append(name)
            }
            do {
                let toolNames = AgentToolRegistry.definitions.compactMap {
                    ($0["function"] as? [String: Any])?["name"] as? String
                }
                let advertised = Set(AgentToolName.allCases.map(\.rawValue))
                try check(
                    Set(toolNames) == advertised && toolNames.count == advertised.count,
                    "Every advertised tool has one registered executor and no duplicate schema")
                try check(
                    DebugHarness.Mode.rankingLiveCheck.requiresLiveServices
                        && !DebugHarness.Mode.selfCheck.requiresLiveServices,
                    "External ranking checks require explicit live-service opt-in; local checks remain local")
                checks += try await RequestBoundaryCheck.run()
                checks += try ModelProfileCheck.run()
                checks += try await RequestTriageCheck.run()
                checks += try await UnifiedRequestCheck.run()
                checks += try await BrowserReadCheck.run(model)
                checks += try await APIDataCheck.run()
                checks += try await FastCardReuseCheck.run()
                model.settings = AppSettings()
                model.busy = true
                model.persistHistory = false
                let endpoint = Endpoint(baseURL: "http://127.0.0.1:19244/v1", model: "fixture")
                try check(endpoint.completionURL?.path == "/v1/chat/completions", "Endpoint normalization")
                try check(
                    Endpoint(baseURL: "http://remote.example/v1", model: "x").completionURL == nil,
                    "Remote credentials require HTTPS")
                var settings = AppSettings()
                settings.theme = .mint
                settings.appearance = .light
                settings.reduceMotion = true
                let settingsData = try JSONEncoder().encode(settings)
                let restoredSettings = try JSONDecoder().decode(AppSettings.self, from: settingsData)
                try check(
                    restoredSettings.theme == .mint && restoredSettings.appearance == .light
                        && restoredSettings.reduceMotion, "Theme and motion preferences round-trip")
                let legacy = Data(
                    "{\"main\":{\"baseURL\":\"https://example.com/v1\",\"model\":\"x\",\"vision\":false}}".utf8)
                let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
                try check(
                    migrated.main.model == "x" && migrated.theme == .iris,
                    "Existing model configuration survives settings migration")
                try check(
                    !String(data: settingsData, encoding: .utf8)!.lowercased().contains("apikey"),
                    "Settings serialization contains no API keys")
                let host = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                host.contentView = model.browser.webView
                model.browser.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:19244/fixture")!))
                for _ in 0..<80 {
                    try await Task.sleep(for: .milliseconds(100))
                    if model.webTitle == "Test library" && !model.webLoading { break }
                }
                let observation = try await model.observation()
                try check(
                    (observation["elements"] as? [[String: Any]])?.isEmpty == false, "Read semantic page elements")
                _ = try await model.browser.webView.evaluateJavaScript(
                    "Object.defineProperty(document.querySelector('audio'),'currentSrc',{get:()=>'', configurable:true}); true"
                )
                let sourceLess = try await model.observation()
                try check(
                    sourceLess["hasMedia"] as? Bool == true,
                    "Loaded streaming media remains detectable without currentSrc")
                _ = try await model.browser.webView.evaluateJavaScript(
                    "delete document.querySelector('audio').currentSrc")
                try check(!JSONText.encode(observation).contains("SHOULD_NOT_LEAK"), "Password values omitted")
                let response = try await ModelClient.complete(
                    endpoint: endpoint, key: "TEST_ONLY", messages: [["role": "user", "content": "fixture"]], tools: [])
                let plan = try InterfaceComposer.decodePlan(response["content"] as? String ?? "")
                let validated = try plan.validated(observation: observation)
                try check(validated.components.count == 4, "Model response composes four native components")
                try check(validated.width <= 320 && validated.height <= 240, "Native control surface stays compact")
                try check(
                    SurfacePlan.webpage.compacted().width <= 340 && SurfacePlan.webpage.compacted().height <= 240,
                    "Default webpage stays a small window")
                _ = try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').loop = true")
                var refused = false
                do {
                    _ = try await model.agent.execute("finish", ["outcome": "media_playing", "reply": "playing"])
                } catch { refused = true }
                try check(refused, "Completion rejects a paused player")
                _ = try await model.performBrowserAction(["action": "media", "operation": "play"])
                _ = try await model.agent.execute("finish", ["outcome": "media_playing", "reply": "playing"])
                try check(
                    model.agent.lastToolVerification?.reply == "playing", "Completion verifies audible advancing media")
                _ = try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').muted = true")
                refused = false
                do {
                    _ = try await model.agent.execute("finish", ["outcome": "media_playing", "reply": "playing"])
                } catch { refused = true }
                try check(refused, "Completion rejects a muted preview")
                _ = try await model.performBrowserAction(["action": "media", "operation": "pause"])
                _ = try await model.agent.execute("finish", ["outcome": "media_paused", "reply": "paused"])
                try check(model.agent.lastToolVerification?.reply == "paused", "Completion verifies pause")
                var unknownMediaRejected = false
                do { _ = try await model.browser.action(["action": "media", "operation": "typo"]) } catch {
                    unknownMediaRejected = true
                }
                let afterUnknown = try await model.browser.observe()
                try check(
                    unknownMediaRejected && afterUnknown["playing"] as? Bool == false,
                    "Unknown media operations fail without accidentally starting playback")
                _ = try await model.browser.action(["action": "media", "operation": "unmute"])
                let mutedPage = try await model.browser.action(["action": "media", "operation": "toggleMute"])
                model.browser.updateState(["ok": true])
                try check(
                    model.browser.lastState["muted"] as? Bool == true,
                    "A click acknowledgement cannot erase verified playback and mute state")
                let unmutedPage = try await model.browser.action(["action": "media", "operation": "toggleMute"])
                try check(
                    mutedPage["muted"] as? Bool == true && unmutedPage["muted"] as? Bool == false
                        && unmutedPage["playing"] as? Bool == false,
                    "Mute toggles are repeatable and never resume a paused track")
                let suite = "app.orvlet.tests." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let cache = SurfaceCache(defaults: defaults)
                let key = SurfaceCache.pageKey("https://example.com/watch?v=one")!
                cache.put(validated, key: key)
                let restored = SurfaceCache(defaults: defaults).get(key)!
                try check(restored.components.count == 4, "UI cache survives reload for the same content")
                try check(
                    SurfaceCache(defaults: defaults).get(SurfaceCache.pageKey("https://example.com/watch?v=two")!)
                        == nil, "Different video IDs cannot inherit another track's generated HTML")
                var staleMedia = validated
                staleMedia.markup = CardMarkup(
                    html: "<h2>Old song</h2><button data-action='toggle'>||</button>", css: "")
                var mediaPage = observation
                mediaPage["mediaPrimary"] = true
                var staleRejected = false
                do { _ = try staleMedia.validated(observation: mediaPage) } catch { staleRejected = true }
                try check(staleRejected, "Saved media HTML with a baked song title and playback state is rejected")
                var dynamicButton = validated
                dynamicButton.actions = [
                    BoundCardAction(
                        id: "toggle",
                        binding: PageBinding(
                            action: "click", role: "button", name: "Pause label that has already changed"))
                ]
                dynamicButton.markup = CardMarkup(
                    html:
                        "<h2 data-bind='title'></h2><small data-bind='status'></small><button data-bind='toggleLabel' data-action='toggle'>Pause</button>",
                    css: "")
                let repairedTransport = try dynamicButton.validated(observation: mediaPage)
                try check(
                    repairedTransport.actions?.first?.binding.action == "media"
                        && repairedTransport.actions?.first?.binding.operation == "toggle",
                    "Live transport labels bind to media semantics even after the webpage button name changes")
                var minimalTransport = repairedTransport
                minimalTransport.markup?.html =
                    "<h2 data-bind='title'></h2><button data-bind='toggleLabel' data-action='toggle'></button>"
                try check(
                    try minimalTransport.validated(observation: mediaPage).markup != nil,
                    "A live transport label represents playback without requiring a redundant status row")
                var muteButton = dynamicButton
                muteButton.actions = [
                    BoundCardAction(
                        id: "sound", binding: PageBinding(action: "click", role: "button", name: "Obsolete mute name"))
                ]
                muteButton.markup = CardMarkup(
                    html:
                        "<h2 data-bind='title'></h2><small data-bind='status'></small><button data-bind='muteLabel' data-action='sound'></button>",
                    css: "")
                try check(
                    try muteButton.validated(observation: mediaPage).actions?.first?.binding.operation == "toggleMute",
                    "Mute labels canonicalize to semantic controls instead of unstable webpage names")
                let next = validated.components[1].actions![1].binding
                _ = try await model.performBrowserAction(next.dictionary)
                let result = try await model.browser.webView.evaluateJavaScript(
                    "document.querySelector('#result').textContent")
                try check(result as? String == "Track Two", "Native action binding clicks actual webpage button")
                var field = validated.components[3].binding!.dictionary
                field["text"] = "hello Orvlet"
                _ = try await model.performBrowserAction(field)
                _ = try await model.performBrowserAction(validated.components[3].submit!.dictionary)
                let searched = try await model.browser.webView.evaluateJavaScript(
                    "document.querySelector('#result').textContent")
                try check(searched as? String == "hello Orvlet", "Native input binding updates and submits page form")
                _ = try await model.performBrowserAction(["action": "key", "key": "ArrowLeft"])
                let count = try await model.browser.webView.evaluateJavaScript("window.keyCount")
                try check((count as? Int ?? 0) > 0, "Generic keyboard input reaches webpage")
                _ = try await model.browser.webView.evaluateJavaScript(
                    "[...document.querySelectorAll('button')].find(b=>b.textContent==='Next item').remove()")
                let changed = try await model.observation()
                var rejected = false
                do { _ = try restored.validated(observation: changed) } catch { rejected = true }
                try check(rejected, "Changed webpage invalidates cached bindings")
                let answers = try await JevClient.judge(
                    endpoint: Endpoint(baseURL: "http://127.0.0.1:19244/v1", model: "fixture"), key: "TEST_ONLY",
                    state: "music", questions: ["audio": "Listening?"])
                try check(answers["audio"] == 0.95, "Jev typed decision protocol")
                model.pinned = true
                let before = model.surface.components.count
                model.install(validated, automatic: true)
                try check(model.surface.components.count == before, "Manual layout pin overrides automatic change")
                let hover = AppModel(defaults: defaults)
                hover.pressedMouseButtonsOverride = 0
                hover.persistHistory = false
                hover.settings.compactLayout = .horizontal
                hover.settings.autoAdapt = false
                hover.webURL = "https://example.com/music"
                hover.install(validated)
                try check(hover.compactSize.height == 44, "Migrated input does not enlarge the 44-point ambient strip")
                var music = validated
                music.components.removeAll { $0.kind == .input }
                hover.install(music)
                try check(
                    hover.compactSize.height == 44,
                    "Music retains a 44-point ambient footprint")
                hover.selectChat(false)
                hover.beginBackgroundListening()
                try check(
                    hover.collapsed && !hover.surface.needsVisual, "Background listening starts compact without video")
                hover.pointerChanged(true)
                hover.reveal()
                try await Task.sleep(for: .milliseconds(300))
                try check(!hover.collapsed && !hover.showingWeb, "Clicking a listening task opens its player card")
                hover.showPage()
                hover.rememberWebSize(NSSize(width: 480, height: 310))
                try check(
                    hover.windowSize == NSSize(width: 480, height: 310),
                    "User webpage dimensions override generated layout sizes")
                let reloaded = AppModel(defaults: defaults)
                try check(
                    reloaded.preferredWebSize == NSSize(width: 480, height: 310),
                    "Webpage dimensions persist across model reload")
                hover.controlInteraction(true)
                hover.pointerChanged(false)
                try await Task.sleep(for: .milliseconds(850))
                try check(!hover.collapsed, "Dragging controls prevents hover dismissal")
                hover.controlInteraction(false)
                try await Task.sleep(for: .milliseconds(850))
                try check(!hover.collapsed, "Clicked details stay open after pointer exit")
                hover.dismissDetailsFromOutsideClick()
                try check(
                    hover.collapsed && hover.windowSize == hover.compactSize,
                    "Outside click returns to the ambient strip")
                hover.rememberWebSize(hover.windowSize)
                try check(
                    hover.preferredWebSize == NSSize(width: 480, height: 310),
                    "Compact size never overwrites saved webpage dimensions")
                hover.pointerChanged(true)
                hover.showPage()
                try await Task.sleep(for: .milliseconds(300))
                hover.selectChat(true)
                hover.pointerChanged(false)
                try await Task.sleep(for: .milliseconds(850))
                try check(
                    !hover.collapsed && hover.chatVisible && hover.showingWeb,
                    "Independent command input preserves an already expanded webpage")
                hover.selectChat(false)
                hover.reveal()
                hover.pinned.toggle()
                try await Task.sleep(for: .milliseconds(850))
                try check(!hover.collapsed, "Pinned player ignores hover dismissal")
                hover.pinned = false
                hover.showPage()
                try await Task.sleep(for: .milliseconds(850))
                try check(!hover.collapsed, "Unpinned clicked webpages remain open without chasing the pointer")
                hover.dismissDetailsFromOutsideClick()
                try check(
                    AppModel.addressURL(" example.com/path ")?.absoluteString == "https://example.com/path",
                    "Address entry accepts bare domains")
                try check(
                    AppModel.addressURL("javascript://alert(1)") == nil && AppModel.addressURL("not a URL") == nil,
                    "Address entry rejects unsafe schemes and whitespace")
                let grounded = try SurfacePlan(
                    components: [SurfaceComponent(kind: .text, label: "Page 2 of 3")], width: 280, height: 120
                ).validated(observation: ["title": "Observed title", "text": "Page 2"])
                try check(
                    grounded.components.first?.label == "Observed title",
                    "Unsupported status claims fall back to observed title")
                let verbatim = try SurfacePlan(
                    components: [SurfaceComponent(kind: .text, label: "Page 2")], width: 280, height: 120
                ).validated(observation: ["title": "Observed title", "text": "Page 2"])
                try check(verbatim.components.first?.label == "Page 2", "Grounded status text is preserved")
                _ = try await model.browser.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture?second",
                ])
                _ = try await model.browser.action(["action": "back"])
                try check(
                    model.webURL == "http://127.0.0.1:19244/fixture" && model.canGoForward,
                    "Native Back restores the previous page")
                _ = try await model.browser.action(["action": "forward"])
                try check(model.webURL.hasSuffix("?second") && model.canGoBack, "Native Forward restores the next page")
                _ = try await model.browser.webView.evaluateJavaScript("window.reloadMarker = true")
                _ = try await model.browser.action(["action": "reload"])
                let marker = try await model.browser.webView.evaluateJavaScript("window.reloadMarker === undefined")
                try check(
                    marker as? Bool == true && model.webURL.hasSuffix("?second"), "Native Reload reloads the same URL")
                var targetError: ToolArgumentError?
                do { _ = try await model.agent.execute("act", ["action": "click", "selector": "button"]) } catch let
                    error as ToolArgumentError
                { targetError = error }
                try check(
                    targetError?.path == "$" && targetError?.issue.contains("nesting") == true,
                    "Undeclared model targets are rejected at the shared argument boundary before page interaction")
                var bindingError = ""
                do {
                    _ = try await model.browser.action(["action": "click", "name": "Missing button", "role": "button"])
                } catch { bindingError = error.localizedDescription }
                try check(
                    bindingError.contains("Binding changed"),
                    "JavaScript action errors reach the agent with their real cause")
                func waitUntil(_ condition: () -> Bool) async throws {
                    let deadline = Date().addingTimeInterval(5)
                    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                    try check(condition(), "Async interaction reached expected state")
                }
                let interactive = AppModel(defaults: defaults)
                interactive.settings.main = endpoint
                interactive.settings.autoAdapt = false
                interactive.persistHistory = false
                interactive.isLiveTest = true
                var calls = 0
                var firstCancelled = false
                var receivedUpdates = false
                interactive.agent.completionOverride = { turns in
                    calls += 1
                    if calls == 1 {
                        do { try await Task.sleep(for: .seconds(10)) } catch {
                            firstCancelled = true
                            throw error
                        }
                        return ["role": "assistant", "content": "Obsolete reply"]
                    }
                    let text = JSONText.encode(turns)
                    receivedUpdates =
                        text.contains("Original request") && text.contains("Actually jazz")
                        && text.contains("Quiet volume")
                    return ["role": "assistant", "content": "Updated request handled"]
                }
                interactive.command = "Original request"
                interactive.sendCommand()
                try await waitUntil { calls == 1 }
                interactive.openTaskConversation(interactive.requestCardID!)
                let steeringStart = Date()
                interactive.command = "Actually jazz"
                interactive.sendCommand()
                interactive.command = "Quiet volume"
                interactive.sendCommand()
                try check(
                    interactive.command.isEmpty && interactive.messages.filter(\.isUser).count == 3,
                    "Busy composer accepts and records every message immediately")
                try await waitUntil { !interactive.busy }
                try check(
                    firstCancelled && receivedUpdates && calls == 2,
                    "New messages cancel in-flight thinking and retain original plus both updates")
                try check(
                    Date().timeIntervalSince(steeringStart) < 2
                        && interactive.messages.last?.text == "Updated request handled",
                    "Steering avoids the ten-second stale response and suppresses obsolete replies")
                try check(
                    interactive.messages.contains(where: { $0.isUser && $0.text == "Actually jazz" }),
                    "Follow-up intent survives in conversation memory")

                var stoppingCalls = 0
                var concurrent = 0
                var peakConcurrent = 0
                interactive.agent.completionOverride = { _ in
                    stoppingCalls += 1
                    concurrent += 1
                    peakConcurrent = max(peakConcurrent, concurrent)
                    defer { concurrent -= 1 }
                    if stoppingCalls == 1 {
                        do { try await Task.sleep(for: .seconds(10)) } catch {}
                        return ["role": "assistant", "content": "Cancelled stale answer"]
                    }
                    return ["role": "assistant", "content": "After stop"]
                }
                interactive.selectChat(true)
                interactive.command = "A slow task"
                interactive.sendCommand()
                try await waitUntil { stoppingCalls == 1 }
                interactive.cancel()
                interactive.command = "New request after stop"
                interactive.sendCommand()
                try await waitUntil { !interactive.busy }
                try check(
                    peakConcurrent == 1 && interactive.messages.last?.text == "After stop",
                    "A message sent during cancellation starts only after the old task exits")
                try check(
                    !interactive.messages.contains { $0.text == "Cancelled stale answer" },
                    "Stop suppresses late results even when a provider ignores cancellation")

                // Reuse the mounted real WebKit fixture for an interruption between tool actions.
                model.settings.main = endpoint
                model.settings.autoAdapt = false
                model.isLiveTest = true
                model.busy = false
                model.pinned = false
                _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
                let freshPage = try await model.observation()
                let reusable = try validated.validated(observation: freshPage)
                model.surface = reusable
                model.hasCustomSurface = true
                model.upsertWebTask(reusable)
                model.openTaskConversation(model.browser.id)
                try check(
                    model.agent.reusablePlan(freshPage) != nil,
                    "Existing validated controls are available to the agent without regeneration")
                model.agent.interpretationOverride = { text in
                    if text == "Start playback then next" {
                        return RequestIntent(kind: .general, needsBrowserContext: true, playbackIntent: "play")
                    }
                    if text == "pause" {
                        var intent = RequestIntent(kind: .general, needsBrowserContext: true, playbackIntent: "pause")
                        intent.targetTaskID = model.browser.id.uuidString
                        return intent
                    }
                    if text == "Actually pause, do not go next" {
                        return RequestIntent(kind: .general, needsBrowserContext: true, playbackIntent: "pause")
                    }
                    return RequestIntent(kind: .general)
                }
                var batchCalls = 0
                var sawWarmContext = false
                func toolCall(_ id: String, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
                    [
                        "id": id, "type": "function",
                        "function": ["name": name, "arguments": JSONText.encode(arguments)],
                    ]
                }
                model.agent.completionOverride = { turns in
                    batchCalls += 1
                    if batchCalls == 1 {
                        sawWarmContext = JSONText.encode(turns).contains("reusable_ui")
                        return [
                            "role": "assistant",
                            "tool_calls": [
                                toolCall("play", "control_media", ["operation": "play"]),
                                toolCall("stale", "act", ["action": "click", "role": "button", "name": "Next item"]),
                            ],
                        ]
                    }
                    return [
                        "role": "assistant",
                        "tool_calls": [
                            toolCall("pause", "control_media", ["operation": "pause"]),
                            toolCall("reuse", "reuse_ui", [:]),
                            toolCall("done", "finish", ["outcome": "media_paused", "reply": "Paused as requested"]),
                        ],
                    ]
                }
                model.command = "Start playback then next"
                model.sendCommand()
                try await waitUntil { model.isPlaying }
                model.command = "Actually pause, do not go next"
                model.sendCommand()
                try await waitUntil { !model.busy }
                let finalPage = try await model.observation()
                try check(
                    sawWarmContext && batchCalls == 2,
                    "Current webpage and reusable controls reach the first model decision")
                try check(
                    finalPage["playing"] as? Bool == false && model.webTitle != "Track Two",
                    "Mid-action steering skips remaining stale tools and applies the new request")
                try check(
                    model.messages.last?.text == "Paused as requested" && model.hasCustomSurface,
                    "Reused UI finishes with verified playback state without compose_ui")
                var shortcutCalls = 0
                model.agent.completionOverride = { _ in
                    shortcutCalls += 1
                    try await Task.sleep(for: .seconds(10))
                    return ["role": "assistant", "content": "Too late"]
                }
                model.controlMedia(model.browser.id, operation: "play")
                try await waitUntil { model.isPlaying }
                model.selectChat(true)
                model.command = "A different slow request"
                model.sendCommand()
                try await waitUntil { shortcutCalls == 1 }
                let pauseStart = Date()
                model.command = "pause"
                model.sendCommand()
                try await waitUntil { !model.isPlaying }
                try check(
                    model.busy && shortcutCalls == 1 && Date().timeIntervalSince(pauseStart) < 2,
                    "A routed pause controls its target while the unrelated model request continues")
                model.cancel()
                try await waitUntil { !model.busy }
                model.agent.completionOverride = nil
                model.agent.interpretationOverride = nil
                hover.pinned = false
                hover.chatVisible = false
                hover.busy = true
                hover.reveal(preview: true)
                hover.pointerChanged(true)
                hover.pointerChanged(false)
                try await Task.sleep(for: .milliseconds(500))
                try check(hover.collapsed, "Pointer exit collapses even while an agent is running")
                hover.pointerChanged(true)
                try await Task.sleep(for: .milliseconds(350))
                try check(hover.collapsed, "Hovering compact controls does not move the pause button by expanding")
                hover.reveal()
                try await Task.sleep(for: .milliseconds(250))
                try check(!hover.collapsed, "Clicking the preview title expands the card")
                hover.pointerChanged(false)
                try await Task.sleep(for: .milliseconds(500))
                hover.webURL = ""
                hover.reveal(preview: true)
                hover.refreshHover()
                try await Task.sleep(for: .milliseconds(500))
                try check(hover.collapsed, "Agent thinking can collapse before any webpage has loaded")
                try check(
                    AppModel.boundedWebSize(NSSize(width: 10, height: 10)) == AppModel.minimumWebSize,
                    "Tiny saved or dragged webpage sizes clamp to a readable minimum")
                var resizedCompact = NSSize.zero
                hover.onResize = { resizedCompact = $0 }
                hover.install(validated)
                try check(
                    hover.windowSize.height == 44 && resizedCompact == .zero,
                    "Changing a migrated plan does not resize the stable compact card")
                try check(
                    !AppSettings().expandOnHover && !migrated.expandOnHover,
                    "Click expansion is the default for new and existing installations")
                var hoverSettings = AppSettings()
                hoverSettings.expandOnHover = true
                let encodedHover = try JSONEncoder().encode(hoverSettings)
                try check(
                    try JSONDecoder().decode(AppSettings.self, from: encodedHover).expandOnHover,
                    "Optional hover expansion survives settings persistence")
                hover.webURL = "https://example.com"
                hover.settings.expandOnHover = true
                hover.pointerChanged(true)
                try await Task.sleep(for: .milliseconds(300))
                try check(hover.collapsed, "Even in hover mode, playback-control area does not expand")
                hover.previewHoverChanged(true)
                try await Task.sleep(for: .milliseconds(300))
                try check(!hover.collapsed, "Optional hover expansion responds only to the preview title")
                let sessionStore = SessionStore(defaults: defaults)
                let savedSession = SavedSession(
                    url: "http://127.0.0.1:19244/fixture", title: "Remembered track", plan: validated, position: 3,
                    volume: 0.05, mediaType: "audio", listening: true, wasPlaying: true)
                sessionStore.put(savedSession)
                sessionStore.put(SavedSession(url: "https://example.com/watch?v=1", title: "One"))
                sessionStore.put(SavedSession(url: "https://example.com/watch?v=2", title: "Two"))
                try check(
                    SessionStore(defaults: defaults).entries.count == 3,
                    "Recent sessions persist exact content URLs rather than merging different tracks")
                sessionStore.put(savedSession)
                let recovered = SessionStore(defaults: defaults).entries.first!
                try check(
                    recovered.plan?.components.count == validated.components.count && recovered.position == 3
                        && recovered.wasPlaying, "Saved session preserves generated controls and playback context")
                sessionStore.put(SavedSession(url: "javascript:alert(1)", title: "Unsafe"))
                try check(sessionStore.entries.count == 3, "Session recovery rejects non-web URLs")
                try check(
                    AppSettings().restoreLastSession && !AppSettings().resumePlaybackOnLaunch
                        && migrated.restoreLastSession,
                    "Startup restores the last page by default without automatic sound")
                _ = try await model.browser.webView.evaluateJavaScript("window.warmRestoreMarker = 'kept'")
                model.restoreSession(savedSession)
                try await waitUntil { !model.restoringSession }
                let warmMarker = try await model.browser.webView.evaluateJavaScript("window.warmRestoreMarker")
                let restoredPage = try await model.observation()
                try check(
                    warmMarker as? String == "kept" && model.hasCustomSurface,
                    "Reopening the current page reuses the live WebView and validates saved UI without a reload")
                try check(
                    restoredPage["playing"] as? Bool == false
                        && abs((restoredPage["currentTime"] as? Double ?? 0) - 3) < 1,
                    "Restore resumes the saved position but stays paused by default")
                model.restoreSession(savedSession)
                model.perform(PageBinding(action: "media", operation: "play"))
                for _ in 0..<50 {
                    if !model.restoringSession && model.isPlaying { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if model.restoringSession || !model.isPlaying {
                    throw AppError.message(
                        "Restore/play race: restoring=\(model.restoringSession), userPause=\(model.browser.userPausedPlayback), restoreHold=\(model.browser.restoringPlayback), interfaceHold=\(model.browser.waitingForInterface), taskRoles=\(model.sideTasks.map { $0.isMediaTask }), error=\(model.feedback?.text ?? "none"), state=\(JSONText.encode(try await model.observation()))"
                    )
                }
                try check(model.isPlaying, "A play click during restore is applied when the page is ready")
                _ = try await model.performBrowserAction(["action": "media", "operation": "pause"])
                let cold = AppModel(defaults: defaults)
                cold.isLiveTest = true
                cold.persistHistory = false
                cold.settings.main = endpoint
                cold.settings.autoAdapt = false
                cold.settings.allowAgents = false
                cold.settings.restoreLastSession = true
                cold.settings.resumePlaybackOnLaunch = false
                let coldHost = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 220), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                coldHost.contentView = cold.browser.webView
                cold.start()
                try check(
                    cold.webTitle == "Remembered track" && cold.collapsed && cold.restoringSession,
                    "Startup immediately restores a compact saved surface before networking completes")
                try await waitUntil { !cold.restoringSession }
                try check(
                    cold.webURL == savedSession.url && cold.hasCustomSurface && !cold.isPlaying,
                    "A fresh app model restores the saved page and bindings without a model request")
                try check(
                    cold.browser.webView.configuration.websiteDataStore.isPersistent,
                    "WebKit uses a persistent website-data store for cache and logins")
                cold.cancelRestoration()

                let notice =
                    "You are cordially invited to a seminar. Speaker: Dr. Alex Example. Date: 5 November 2026 (Thursday). Time: 2:00 pm - 3:00 pm. Venue: Room 101."
                let draft = CalendarDraft(
                    title: "Reliable Interactive Systems — Dr. Alex Example", start: "2026-11-05T14:00:00",
                    end: "2026-11-05T15:00:00", timeZone: "Asia/Hong_Kong", category: "work", kind: "seminar",
                    location: "Room 101", notes: notice)
                let prepared = try CalendarService.prepare(
                    draft, calendar: "工作", hostTimeZone: TimeZone(secondsFromGMT: 0)!)
                try check(
                    prepared.start == "2026-11-05T06:00:00" && prepared.end == "2026-11-05T07:00:00",
                    "Calendar events convert source time zone to host-local AppleScript dates")
                var missingEnd = draft
                missingEnd.end = nil
                let assumed = try CalendarService.prepare(missingEnd, calendar: "工作")
                try check(
                    assumed.assumedEnd && assumed.notes.contains("one hour"),
                    "A seminar without an end gets an explicit one-hour assumption")
                var invalidDate = draft
                invalidDate.start = "2026-02-30T14:00:00"
                var rejectedDate = false
                do { _ = try CalendarService.prepare(invalidDate, calendar: "工作") } catch { rejectedDate = true }
                try check(rejectedDate, "Invalid calendar dates are rejected before executing AppleScript")
                var literal = draft
                literal.title = "Quotes \" and $(not-a-command)"
                literal.notes = "Line one\nLine two"
                let literalPrepared = try CalendarService.prepare(literal, calendar: "工作")
                try check(
                    literalPrepared.arguments.count == 9 && literalPrepared.arguments[2] == literal.title
                        && literalPrepared.arguments[6].contains("Line one\nLine two"),
                    "Calendar text is passed as literal arguments, never executable script source")
                let calendar = CalendarService()
                let journalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "orvlet-calendar-test-" + UUID().uuidString)
                calendar.journalDirectory = journalRoot
                defer { try? FileManager.default.removeItem(at: journalRoot) }
                var written: [String: Any]?
                var writes = 0
                calendar.runnerOverride = { args in
                    switch args[0] {
                    case "list":
                        return "[{\"name\":\"Read only\",\"writable\":false},{\"name\":\"工作\",\"writable\":true}]"
                    case "find": return JSONText.encode(written.map { [$0] } ?? [])
                    case "create":
                        writes += 1
                        written = [
                            "status": "created", "uid": "test-event", "calendar": args[1], "title": args[2],
                            "start": args[3], "end": args[4], "location": args[5], "notes": args[6], "url": args[7],
                            "allDay": args[8] == "true",
                        ]
                        return JSONText.encode(written!)
                    case "read": return JSONText.encode(written!)
                    default: throw AppError.message("Unexpected calendar command")
                    }
                }
                let added = try await calendar.create(draft)
                try check(
                    added["verified"] as? Bool == true && added["calendar"] as? String == "工作" && writes == 1,
                    "Calendar action chooses a writable work calendar and requires read-back")
                let duplicate = try await calendar.create(draft)
                try check(
                    duplicate["status"] as? String == "exists" && writes == 1,
                    "Repeating the same calendar request does not create a duplicate")
                var alternate = draft
                alternate.title += " (Seminar)"
                let possible = try await calendar.create(alternate)
                try check(
                    possible["status"] as? String == "possible_duplicate" && writes == 1,
                    "A reworded event at the same time and venue is flagged before creating")
                written = nil
                var cancelledWrite = false
                do { _ = try await calendar.create(draft, shouldProceed: { false }) } catch { cancelledWrite = true }
                try check(
                    cancelledWrite && writes == 1, "A new user instruction can stop a calendar write before it commits")
                calendar.journalDirectory = journalRoot.appendingPathComponent("uncertain")
                calendar.runnerOverride = { args in
                    if args[0] == "list" { return "[{\"name\":\"工作\",\"writable\":true}]" }
                    if args[0] == "find" { return "[]" }
                    if args[0] == "create" {
                        writes += 1
                        throw AppError.message("Simulated uncertain response")
                    }
                    throw AppError.message("Unexpected read")
                }
                do { _ = try await calendar.create(draft) } catch {}
                let writesAfterFailure = writes
                do { _ = try await calendar.create(draft) } catch {}
                try check(
                    writes == writesAfterFailure, "An uncertain calendar write is journaled and never blindly retried")
                let scriptValidation = try await CalendarService().run(["validate", "2026-11-05T14:00:00"])
                try check(
                    scriptValidation == "2026-11-05T14:00:00",
                    "Native Calendar date validation does not access or write calendars")
                checks += try await CalendarOutcomeCheck.run()
                checks += try await RequestRoutingCheck.run()
                checks += try await TaskRuntimeCheck.run()
                checks += try await LocalCredentialsCheck.run()
                let switching = AppModel(defaults: defaults)
                switching.isLiveTest = true
                switching.persistHistory = false
                switching.settings.autoAdapt = false
                _ = try await switching.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
                switching.install(validated)
                switching.hasCustomSurface = true
                switching.settings.main = endpoint
                switching.settings.autoAdapt = true
                var composing = false
                switching.adaptive.compositionOverride = { _ in
                    composing = true
                    // Deliberately ignore cancellation, as an in-flight provider response may do.
                    try? await Task.sleep(for: .milliseconds(600))
                    return SurfacePlan(
                        components: [], width: 320, height: 160,
                        markup: CardMarkup(html: "<p>Obsolete generated card</p>", css: ""))
                }
                switching.adaptive.changed(force: true)
                for _ in 0..<60 {
                    if composing { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                try check(composing, "Delayed interface generation begins for the original browser")
                let original = switching.browser
                try switching.prepareBrowserForNewTask()
                switching.webURL = "https://example.com/new-task"
                switching.surface = .webpage
                try await Task.sleep(for: .milliseconds(700))
                try check(
                    switching.browser !== original && switching.surface.markup == nil && !switching.buildingSurface,
                    "Switching tasks rejects an obsolete generated interface even if its provider ignores cancellation (switched=\(switching.browser !== original), markup=\(switching.surface.markup != nil), building=\(switching.buildingSurface))"
                )
                switching.closeWebTask(original.id)
                original.updateState([
                    "url": "https://example.com/stale", "title": "Closed task callback", "hasMedia": true,
                ])
                var disposedRejected = false
                do { _ = try await original.action(["action": "media", "operation": "play"]) } catch {
                    disposedRejected = true
                }
                try check(
                    disposedRejected && !switching.sideTasks.contains(where: { $0.id == original.id })
                        && switching.webURL == "https://example.com/new-task",
                    "Disposed browsers reject actions and late state cannot resurrect or overwrite a task")
                switching.browser.dispose()
                let quiet = AppModel(defaults: defaults)
                quiet.isLiveTest = true
                quiet.persistHistory = false
                let oldBrowser = BrowserController(model: quiet)
                quiet.parkedBrowsers[oldBrowser.id] = oldBrowser
                var oldMusic = SideTask(id: oldBrowser.id, kind: .web, title: "Earlier paused song")
                oldMusic.hasMedia = true
                oldMusic.listening = true
                var currentMusic = SideTask(id: quiet.browser.id, kind: .web, title: "Current song")
                currentMusic.hasMedia = true
                currentMusic.listening = true
                currentMusic.playing = true
                let liveTimer = SideTask(kind: .timer, title: "Active timer", deadline: Date().addingTimeInterval(600))
                quiet.sideTasks = [oldMusic, currentMusic, liveTimer]
                quiet.ambientRequestID = currentMusic.id
                try check(
                    quiet.ambientTasks.map(\.id) == [currentMusic.id, liveTimer.id],
                    "An older paused player cannot push the active timer out beside the current music")
                let work = SideTask(kind: .workspace, title: "Text cleanup", status: "Ready")
                quiet.sideTasks.append(work)
                quiet.ambientRequestID = work.id
                quiet.preferredMediaTaskID = currentMusic.id
                quiet.sideTasks[1].playing = false
                try check(
                    quiet.ambientTasks.map(\.id) == [work.id, currentMusic.id],
                    "Pausing the preferred music keeps its control beside the current task")
                quiet.deliverReply("Text cleanup ready", kind: .success, taskID: work.id)
                try check(
                    quiet.feedback == nil && quiet.hasUnreadReply,
                    "A ready generated card reports success quietly without an unsolicited expanded receipt")
                quiet.taskShelfVisible = true
                try check(
                    (quiet.shellContentSize?.height ?? 1000) < 300,
                    "A short task list uses content-sized height rather than an empty dashboard")
                quiet.browser.dispose()
                oldBrowser.dispose()
                let data = try JSONSerialization.data(
                    withJSONObject: ["passed": checks.count, "checks": checks], options: .prettyPrinted)
                try data.write(to: URL(fileURLWithPath: "/tmp/orvlet-checks.json"))
                print(String(data: data, encoding: .utf8)!)
                exit(0)
            } catch {
                let output: [String: Any] = [
                    "passed": checks.count, "checks": checks, "error": error.localizedDescription,
                ]
                print(JSONText.encode(output))
                try? Data(JSONText.encode(output).utf8).write(to: URL(fileURLWithPath: "/tmp/orvlet-checks.json"))
                exit(1)
            }
        }
    }
#endif
