#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum TaskSurfaceUICheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(200)) }
            func descendants(_ root: NSView) -> [WKWebView] {
                (root as? WKWebView).map { [$0] } ?? root.subviews.flatMap(descendants)
            }
            model.dismissFeedback()
            model.selectChat(false)
            model.collapse()
            model.sideTasks.removeAll()
            for browser in model.parkedBrowsers.values { browser.dispose() }
            model.parkedBrowsers.removeAll()
            model.browser.dispose()
            model.browser = BrowserController(model: model)
            model.webURL = ""
            model.hasMedia = false
            model.settings.main = Endpoint()
            model.settings.autoAdapt = false
            model.settings.appearance = .light
            model.setCompactLayout(.vertical)
            _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
            _ = try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').loop=true")
            _ = try await model.browser.action(["action": "media", "operation": "play"])
            model.beginBackgroundListening()
            let music = model.browser
            let musicID = music.id
            let start =
                (try await music.webView.evaluateJavaScript("document.querySelector('audio').currentTime")) as? Double
                ?? 0
            let id = UUID()
            var specimen = TaskRuntimeCheck.surface()
            // Model-authored palettes and inline styles must not fork the product's art direction.
            specimen.markup.css =
                "#surface .calm-value{color:#ff0000!important;font-family:Papyrus!important;text-shadow:0 0 4px red}#surface button{background:#00ff00!important;border-color:red!important}"
            specimen.markup.html = specimen.markup.html.replacingOccurrences(
                of: "class='calm-primary'",
                with:
                    "class='calm-primary' style='font-family:Papyrus!important;color:red!important;box-shadow:0 0 20px red'"
            )
            let surface = try specimen.validated()
            model.publishTaskSurface(surface, id: id)
            model.activeRequest = nil
            try check(
                model.ambientTasks.contains(where: { $0.id == musicID })
                    && model.ambientTasks.contains(where: { $0.id == id }),
                "A generated task and music share the compact stack with the native playback control retained")
            model.selectTask(id, expanded: true)
            var card: WKWebView?
            for _ in 0..<40 {
                for web in descendants(delegate.panel.contentView!) {
                    if (try? await web.evaluateJavaScript("!!document.querySelector('[data-field=amount]')")) as? Bool
                        == true
                    {
                        card = web
                        break
                    }
                }
                if card != nil { break }
                try await pause()
            }
            guard let card else { throw AppError.message("Task form did not render") }
            try await pause()
            try check(
                (try await card.evaluateJavaScript("document.querySelector('[data-field=amount]').value")) as? String
                    == "120", "A generated multi-field form initializes from its task state")
            _ = try await card.evaluateJavaScript(
                "window.__taskSentinel=42;document.querySelector('[data-field=amount]').value='150';document.querySelector('[data-field=people]').value='5';document.querySelector('[data-action=calculate]').click()"
            )
            for _ in 0..<60 {
                if model.sideTasks.first(where: { $0.id == id })?.state["share"] == "30.00" { break }
                try await pause()
            }
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["share"] == "30.00",
                "A rendered task button sends all form fields to the real code worker")
            try await pause()
            let rendered =
                try await card.evaluateJavaScript("document.querySelector('[data-bind=share]').textContent") as? String
            let sentinel = try await card.evaluateJavaScript("window.__taskSentinel") as? Int
            try check(
                rendered == "30.00" && sentinel == 42,
                "Verified results update the live interface without reloading its document")
            try check(
                (try await card.evaluateJavaScript("document.querySelector('[data-field=amount]').value")) as? String
                    == "150", "A calculation status refresh preserves the submitted inputs")
            let after =
                (try await music.webView.evaluateJavaScript("document.querySelector('audio').currentTime")) as? Double
                ?? 0
            try check(
                model.browser === music && after > start && model.backgroundListening && !model.showingWeb
                    && !model.commandPanelVisible,
                "Generated code and expanded task UI leave the existing player, playback and input window unchanged")
            try await pause()
            let controlsFit =
                try await card.evaluateJavaScript(
                    "[...document.querySelectorAll('button,input')].every(n=>{const r=n.getBoundingClientRect();return r.right<=innerWidth && r.bottom<=innerHeight && r.left>=0})"
                ) as? Bool
            try check(controlsFit == true, "Generated forms fit their measured card without clipped fields or buttons")
            let artDirection =
                try await card.evaluateJavaScript(
                    "(()=>{const value=document.querySelector('.calm-value'),button=document.querySelector('.calm-primary'),v=getComputedStyle(value),b=getComputedStyle(button);return v.color===getComputedStyle(document.body).color&&!v.fontFamily.includes('Papyrus')&&!b.fontFamily.includes('Papyrus')&&v.textShadow==='none'&&b.boxShadow==='none'&&parseFloat(b.borderRadius)===10&&b.backgroundColor!== 'rgb(0, 255, 0)'})()"
                ) as? Bool
            try check(
                artDirection == true,
                "Model CSS and inline styles cannot replace the shared palette, typeface or control material")
            let layoutQuality =
                try await card.evaluateJavaScript(
                    "(()=>{const root=document.querySelector('.calm-surface').getBoundingClientRect(),result=document.querySelector('.calm-result').getBoundingClientRect(),fields=[...document.querySelectorAll('.calm-field')].map(n=>n.getBoundingClientRect()),actions=document.querySelector('.calm-actions').getBoundingClientRect();return Math.abs(root.left-(innerWidth-root.right))<1&&Math.abs(result.left-fields[0].left)<1&&Math.abs(fields[0].width-fields[1].width)<1&&actions.top>=fields[0].bottom+12&&document.querySelector('#surface').scrollWidth<=document.querySelector('#surface').clientWidth})()"
                ) as? Bool
            try check(
                layoutQuality == true,
                "Shared primitives produce balanced margins, aligned results, equal input columns and separated actions"
            )
            var compactCard: WKWebView?
            for web in descendants(delegate.panel.contentView!) {
                if (try? await web.evaluateJavaScript(
                    "document.documentElement.dataset.compact==='true'&&!!document.querySelector('.calm-glance [data-bind=share]')"
                )) as? Bool == true {
                    compactCard = web
                    break
                }
            }
            guard let compactCard else { throw AppError.message("Compact result glance did not render") }
            let glanceFits =
                try await compactCard.evaluateJavaScript(
                    "(()=>{const value=document.querySelector('.calm-value'),label=document.querySelector('.calm-label'),r=value.getBoundingClientRect(),l=label.getBoundingClientRect();return getComputedStyle(value).fontSize==='12px'&&getComputedStyle(label).fontSize==='9px'&&r.right<=innerWidth&&r.bottom<=innerHeight&&l.top>=0&&r.left>=26&&document.querySelectorAll('button,input').length===0})()"
                ) as? Bool
            try check(
                glanceFits == true,
                "A generated compact result keeps its shared 12/9 typography inside the 82 by 28 content canvas without extra controls"
            )
            let lightInk =
                try await card.evaluateJavaScript("getComputedStyle(document.querySelector('.calm-value')).color")
                as? String
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-independent-task-light.png")
            model.settings.appearance = .dark
            try await pause()
            let darkInk =
                try await card.evaluateJavaScript("getComputedStyle(document.querySelector('.calm-value')).color")
                as? String
            try check(
                darkInk != lightInk,
                "Generated content follows the host's light and dark ink colors despite author palette overrides")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-independent-task-dark.png")
            model.settings.appearance = .light
            model.controlMedia(musicID, operation: "pause")
            for _ in 0..<30 {
                if (try await music.webView.evaluateJavaScript("document.querySelector('audio').paused")) as? Bool
                    == true
                {
                    break
                }
                try await pause()
            }
            try check(
                (try await music.webView.evaluateJavaScript("document.querySelector('audio').paused")) as? Bool == true
                    && model.selectedTaskID == id,
                "The music pause control works while a different generated task is open")
            model.controlMedia(musicID, operation: "play")
            try await pause()
            model.closeTask(id)
            try check(
                model.browser === music && model.sideTasks.contains(where: { $0.id == musicID })
                    && !model.sideTasks.contains(where: { $0.id == id }),
                "Closing an independent task leaves the music browser alive")
            var textSurface = TaskRuntimeCheck.surface()
            textSurface.title = "Text tool"
            textSurface.fields = ["text", "choice", "enabled"]
            textSurface.markup = CardMarkup(
                html:
                    "<section class='calm-stack'><textarea rows='2' data-field='text'></textarea><select data-field='choice'><option value='A'>First</option><option value='B'>Second</option></select><label><input type='checkbox' data-field='enabled'>Include</label><button data-action='apply'>Apply</button><p data-bind='echo'></p></section>",
                css: "", height: 230)
            textSurface.state = ["text": "hello", "choice": "A", "enabled": "false", "echo": ""]
            textSurface.actions = [
                TaskSurfaceAction(
                    id: "apply", kind: .code,
                    code: "return {state:{echo:[input.text,input.choice,input.enabled].join('|')}};")
            ]
            let textID = UUID()
            model.publishTaskSurface(try textSurface.validated(), id: textID)
            model.activeRequest = nil
            model.selectTask(textID, expanded: true)
            var textCard: WKWebView?
            for _ in 0..<40 {
                for web in descendants(delegate.panel.contentView!) {
                    if (try? await web.evaluateJavaScript("!!document.querySelector('textarea')")) as? Bool == true {
                        textCard = web
                        break
                    }
                }
                if textCard != nil { break }
                try await pause()
            }
            guard let textCard else { throw AppError.message("Text form did not render") }
            try await pause()
            _ = try await textCard.evaluateJavaScript(
                "document.querySelector('textarea').value='hello world';document.querySelector('select').value='B';document.querySelector('input[type=checkbox]').checked=true;document.querySelector('button').click()"
            )
            for _ in 0..<60 {
                if model.sideTasks.first(where: { $0.id == textID })?.state["echo"] == "hello world|B|true" { break }
                try await pause()
            }
            try check(
                model.sideTasks.first(where: { $0.id == textID })?.state["echo"] == "hello world|B|true",
                "Generated text areas, choices and checkboxes pass typed form values to their own code")
            model.closeTask(textID)
            try model.prepareBrowserForNewTask()
            let second = model.browser
            _ = try await second.action(["action": "navigate", "url": "http://127.0.0.1:19244/live-reading"])
            model.upsertWebTask(.webpage, activate: true)
            model.selectTask(musicID, expanded: true)
            model.agent.interpretationOverride = { _ in
                RequestIntent(kind: .general, needsBrowserContext: true, playbackIntent: "pause")
            }
            model.agent.completionOverride = { _ in
                [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": "pause-selected", "type": "function",
                            "function": ["name": "control_media", "arguments": "{\"operation\":\"pause\"}"],
                        ],
                        [
                            "id": "finish-selected", "type": "function",
                            "function": [
                                "name": "finish", "arguments": "{\"outcome\":\"media_paused\",\"reply\":\"Paused\"}",
                            ],
                        ],
                    ],
                ]
            }
            _ = try await model.agent.run("Pause the player I selected")
            try check(
                model.browser === music && model.sideTasks.first(where: { $0.id == musicID })?.playing == false,
                "Explicit browser requests still activate the selected player rather than the most recently created page"
            )
            model.agent.interpretationOverride = nil
            model.agent.completionOverride = nil
            model.closeWebTask(second.id)
            let liveMusicPlan = SurfacePlan(
                components: [], width: 320, height: 160,
                markup: CardMarkup(
                    html:
                        "<section class='calm-surface'><div class='calm-stack'><h2 class='calm-title' data-bind='title'></h2><small class='calm-label' data-bind='status'></small></div><div class='calm-actions'><button class='calm-primary' data-action='transport'>||</button><button class='calm-secondary' data-action='sound' data-bind='muteLabel'></button></div></section>",
                    css: "", height: 125),
                actions: [
                    BoundCardAction(id: "transport", binding: PageBinding(action: "media", operation: "toggle")),
                    BoundCardAction(id: "sound", binding: PageBinding(action: "media", operation: "toggleMute")),
                ])
            let musicObservation = try await model.observation()
            model.install(try liveMusicPlan.validated(observation: musicObservation))
            model.upsertWebTask(model.surface)
            model.selectTask(musicID, expanded: true)
            var player: WKWebView?
            for _ in 0..<30 {
                for web in descendants(delegate.panel.contentView!) {
                    if (try? await web.evaluateJavaScript("!!document.querySelector('button[data-action=transport]')"))
                        as? Bool == true
                    {
                        player = web
                        break
                    }
                }
                if player != nil { break }
                try await pause()
            }
            guard let player else { throw AppError.message("Generated media controls did not render") }
            try await pause()
            try check(
                (try await player.evaluateJavaScript(
                    "document.querySelector('[data-action=transport]').getAttribute('aria-label')")) as? String
                    == "Play", "A paused generated player replaces a literal pause glyph with the truthful Play control"
            )
            _ = try await player.evaluateJavaScript("document.querySelector('[data-action=transport]').click()")
            for _ in 0..<30 {
                if model.sideTasks.first(where: { $0.id == musicID })?.playing == true { break }
                try await pause()
            }
            try await pause()
            try check(
                (try await player.evaluateJavaScript(
                    "document.querySelector('[data-action=transport]').getAttribute('aria-label')")) as? String
                    == "Pause", "The generated transport switches icon and label after real playback starts")
            _ = try await player.evaluateJavaScript("document.querySelector('[data-action=sound]').click()")
            for _ in 0..<30 {
                if model.sideTasks.first(where: { $0.id == musicID })?.muted == true { break }
                try await pause()
            }
            try await pause()
            try check(
                (try await player.evaluateJavaScript("document.querySelector('[data-action=sound]').textContent"))
                    as? String == "Unmute", "A generated sound control reflects verified mute state")
            _ = try await player.evaluateJavaScript("document.querySelector('[data-action=sound]').click()")
            for _ in 0..<30 {
                if model.sideTasks.first(where: { $0.id == musicID })?.muted == false { break }
                try await pause()
            }
            try await pause()
            try check(
                (try await player.evaluateJavaScript("document.querySelector('[data-action=sound]').textContent"))
                    as? String == "Mute", "The same generated sound control works again after its label changes")
            if let i = model.sideTasks.firstIndex(where: { $0.id == musicID }) {
                model.sideTasks[i].plan?.actions?.append(
                    BoundCardAction(
                        id: "stale",
                        binding: PageBinding(action: "click", role: "button", name: "Removed secondary control")))
            }
            model.cardAction(musicID, action: "transport", value: nil)
            for _ in 0..<30 {
                if model.sideTasks.first(where: { $0.id == musicID })?.playing == false { break }
                try await pause()
            }
            try check(
                model.sideTasks.first(where: { $0.id == musicID })?.playing == false && model.feedback == nil,
                "An obsolete secondary webpage control cannot disable the player's working pause button")
            model.deliverReply("Synthetic feedback: this must never cover the player's controls.", kind: .failure)
            try await pause()
            let feedbackTop = model.shellLayout.content.minY + model.feedbackSize.height
            let playerBounds = delegate.panel.convertToScreen(player.convert(player.bounds, to: nil))
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-player-feedback-fixed.png")
            try check(
                playerBounds.minY >= feedbackTop - 1,
                "Expanded feedback occupies its own region below the player rather than overlaying controls: player=\(playerBounds), receiptTop=\(feedbackTop)"
            )
            model.dismissFeedback()
            model.collapse()
            model.selectTask(musicID, expanded: true)
            try await pause()
            let reopenedTitle =
                try await player.evaluateJavaScript("document.querySelector('[data-bind=title]').textContent")
                as? String
            try check(
                model.selectedSideTask?.id == musicID && reopenedTitle == model.selectedSideTask?.title,
                "Reopening a player keeps its title bound to its owning task")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-player-fixed.png")
            model.closeWebTask(musicID)
            return checks
        }
    }
#endif
