#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum TaskExperienceCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ text: String) throws {
                guard ok else { throw AppError.message("Check failed: " + text) }
                checks.append(text)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(500)) }
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
            model.agent.completionOverride = { _ in
                try await Task.sleep(for: .milliseconds(750))
                return ["role": "assistant", "content": "Background reply"]
            }
            model.selectChat(true)
            model.command = "Explain a small idea"
            model.sendCommand()
            try check(
                model.busy && !model.commandPanelVisible && !model.shellExpanded,
                "Submission immediately collapses input while the agent keeps working")
            for _ in 0..<30 {
                if !model.busy { break }
                try await pause()
            }
            try check(
                !model.busy && !model.shellExpanded && model.hasUnreadReply
                    && model.messages.last?.text == "Background reply",
                "Background completion leaves a quiet unread result without reopening the interface")
            model.selectChat(true)
            try check(!model.hasUnreadReply, "Reopening input reads the result and clears its indicator")
            model.selectChat(false, restoreFocus: false)
            model.agent.completionOverride = nil
            model.settings.main = Endpoint()
            let page = try await model.browser.action([
                "action": "navigate", "url": "http://127.0.0.1:19244/live-reading",
            ])
            try check(
                page["mediaPrimary"] as? Bool == false,
                "A page's hidden sound element does not classify it as a media task")
            var plan = SurfacePlan(components: [], width: 320, height: 150, title: "Live status")
            plan.markup = CardMarkup(
                html: "<strong data-bind='value'></strong>",
                compactHTML:
                    "<div class='calm-glance'><small class='calm-label'>Local time</small><strong class='calm-value' data-bind='value'></strong></div>",
                css: "strong{font-size:13px;font-variant-numeric:tabular-nums}", height: 120)
            plan.actions = []
            plan.readings = [CardReading(key: "value", selector: "#reading")]
            let checked = try plan.validated(observation: page)
            var unsafe = plan
            unsafe.readings = [CardReading(key: "value", selector: "input[type=password]")]
            var rejected = false
            do { _ = try unsafe.validated(observation: page) } catch { rejected = true }
            try check(rejected, "A model cannot invent an unobserved live-reading selector")
            var wrongMedia = plan
            wrongMedia.actions = [BoundCardAction(id: "play", binding: PageBinding(action: "media", operation: "play"))]
            rejected = false
            do { _ = try wrongMedia.validated(observation: page) } catch { rejected = true }
            try check(rejected, "Incidental audio cannot be bound as a generated player")
            model.install(checked)
            model.upsertWebTask(checked, activate: true)
            model.collapse()
            try await pause()
            try await model.browser.bindReadings(checked.readings ?? [])
            let taskID = model.browser.id
            let first = model.sideTasks.first(where: { $0.id == taskID })!.state["value"]
            // WebKit and the page tick independently; allow their next updates to arrive.
            var second = first
            for _ in 0..<10 {
                try await pause()
                second = model.sideTasks.first(where: { $0.id == taskID })!.state["value"]
                if second != first { break }
            }
            try check(
                first != nil && first != second && !model.quickMediaTasks.contains(where: { $0.id == taskID }),
                "Live webpage values update locally without becoming a player")
            // Make this test task visible in the bounded ambient area.
            for i in model.sideTasks.indices where model.sideTasks[i].id != taskID { model.sideTasks[i].hidden = true }
            model.reconcileTasks()
            try await pause()
            func webViews(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
            }
            var compact: WKWebView?
            for web in webViews(delegate.panel.contentView!) {
                if (try? await web.evaluateJavaScript("window.isCompact === true")) as? Bool == true {
                    compact = web
                    break
                }
            }
            guard let compact else { throw AppError.message("Generated compact view did not render") }
            let rendered =
                try await compact.evaluateJavaScript("document.querySelector('[data-bind=value]').textContent")
                as? String
            try check(
                rendered == model.sideTasks.first(where: { $0.id == taskID })!.state["value"],
                "The compact generated HTML displays the real bound value")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-live-reading-compact.png")
            let fits =
                try await compact.evaluateJavaScript(
                    "(()=>{const s=document.querySelector('#surface'),v=document.querySelector('[data-bind=value]'),r=v.getBoundingClientRect();return r.left>=26&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1&&s.scrollWidth<=s.clientWidth&&parseFloat(getComputedStyle(v).fontSize)===12})()"
                ) as? Bool
            try check(fits == true, "Generated compact typography fits beside the host glyph without clipping")
            let lightInk = try await compact.evaluateJavaScript("getComputedStyle(document.body).color") as? String
            model.settings.appearance = .dark
            try await pause()
            let darkInk = try await compact.evaluateJavaScript("getComputedStyle(document.body).color") as? String
            try check(
                lightInk != darkInk,
                "Generated typography follows the same light and dark appearance as the native shell")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-live-reading-dark.png")
            model.settings.appearance = .light
            model.setCompactLayout(.horizontal)
            try await pause()
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-live-reading-horizontal.png")
            model.setCompactLayout(.vertical)
            try await pause()
            let timer = try model.startTimer(seconds: 600, title: "Close test")
            model.closeTask(timer)
            try check(
                !model.sideTasks.contains(where: { $0.id == timer }),
                "Closing a timer removes its deadline and task without stopping other tasks")
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
            model.agent.completionOverride = { _ in
                try await Task.sleep(for: .milliseconds(750))
                return ["role": "assistant", "content": "Unrelated reply continues"]
            }
            model.command = "Explain another small idea"
            model.sendCommand()
            model.closeTask(taskID)
            try check(
                !model.sideTasks.contains(where: { $0.id == taskID }) && model.browser.id != taskID,
                "Closing a webpage releases its source context directly")
            for _ in 0..<30 {
                if !model.busy { break }
                try await pause()
            }
            try check(
                model.messages.last?.text == "Unrelated reply continues",
                "Closing a webpage does not cancel unrelated background thinking")
            model.agent.completionOverride = nil
            model.settings.main = Endpoint()
            return checks
        }
    }
#endif
