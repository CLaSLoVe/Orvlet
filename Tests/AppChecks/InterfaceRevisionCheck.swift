#if DEBUG
    import AppKit

    @MainActor
    enum InterfaceRevisionCheck {
        static func start() {
            do {
                let checks = try run()
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: .prettyPrinted)
                    .write(to: URL(fileURLWithPath: "/tmp/orvlet-interface-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-interface-checks.json"))
                exit(1)
            }
        }
        static func run() throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            var a = SideTask(kind: .web, title: "Music")
            a.listening = true
            a.playing = true
            a.sourceURL = "https://example.com/track"
            let b = SideTask(kind: .workspace, title: "Other task")
            model.sideTasks = [a, b]
            model.selectedTaskID = b.id
            model.editInterface(a.id)
            try check(
                model.editingInterfaceID == a.id && model.commandPanelVisible && model.selectedTaskID == b.id,
                "Interface editing targets the chosen task without switching the active browser or other task")
            model.selectedTaskID = b.id
            try check(
                model.editingInterfaceTask?.id == a.id, "Opening another task cannot retarget the editing conversation")
            model.selectChat(false)
            try check(
                model.editingInterfaceID == nil, "Dismissed editing context cannot leak into a later general request")
            model.editInterface(a.id)
            model.selectChat(true)
            try check(model.editingInterfaceID == nil, "A normal Add entry always starts a general request")
            model.selectChat(false)
            let markup = CardMarkup(
                html:
                    "<section class='calm-surface'><strong data-bind='title'></strong><button data-action='toggle' data-bind='toggleLabel'></button></section>",
                compactHTML: "<span data-bind='status'></span>", css: "", height: 130)
            try model.applyInterfaceRevision(a.id, markup: markup, original: a)
            try check(
                model.sideTasks[0].id == a.id && model.sideTasks[0].playing
                    && model.sideTasks[0].sourceURL == a.sourceURL && model.sideTasks.count == 2,
                "An interface edit preserves task identity, playback and source URL")
            try check(
                model.sideTasks[0].customCompact == true && model.sideTasks[0].presentation == markup
                    && model.sideTasks[1].presentation == b.presentation,
                "Only the intended panel and compact view change")
            let restored = try JSONDecoder().decode(SideTask.self, from: JSONEncoder().encode(model.sideTasks[0]))
            try check(
                restored.customCompact == true && restored.presentation == markup,
                "Customized compact presentation survives task persistence")
            var refused = false
            do { try model.applyInterfaceRevision(a.id, markup: markup, original: a) } catch { refused = true }
            try check(refused, "An older interface response cannot overwrite a newer edit")
            let current = model.sideTasks[0]
            var invalid = markup
            invalid.html = "<button data-action='made_up'>Go</button>"
            refused = false
            do { try model.applyInterfaceRevision(a.id, markup: invalid, original: current) } catch { refused = true }
            try check(
                refused && model.sideTasks[0].presentation == markup,
                "Unsupported controls are rejected atomically without breaking the current card")
            invalid = markup
            invalid.compactHTML = "<span data-bind='unavailable_duration'></span>"
            refused = false
            do { try model.applyInterfaceRevision(a.id, markup: invalid, original: current) } catch { refused = true }
            try check(
                refused && model.sideTasks[0].presentation == markup,
                "Unsupported live readings cannot produce a silently empty customized card")
            model.updateBackgroundTask(a.id, data: ["url": "https://example.com/other"])
            try check(
                model.sideTasks[0].markup == nil && model.sideTasks[0].customCompact == nil,
                "Navigating to different content clears its previous customized compact view")
            refused = false
            do { try model.applyInterfaceRevision(a.id, markup: markup, original: current) } catch { refused = true }
            try check(refused, "Page navigation invalidates an edit generated for older content")
            model.sideTasks.removeAll { $0.id == a.id }
            refused = false
            do { try model.applyInterfaceRevision(a.id, markup: markup, original: current) } catch { refused = true }
            try check(refused && model.sideTasks.count == 1, "A delayed edit cannot resurrect a closed task")
            return checks
        }
    }
#endif
