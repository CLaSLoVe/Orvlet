#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// Cold designs, live configured services and the production shell. Synthetic input only.
@MainActor
enum GenerativeLatencyCheck {
    struct Sample {
        let id: String
        let prompt: String
        let before: String
        let after: String
        var usesForm = false
    }

    static let samples = [
        Sample(id: "proof-marks", prompt: "做一个样片标记计数器，从 0 开始。在胶囊点一次就加 1，展开后也能减 1。", before: "0", after: "1"),
        Sample(id: "proof-stages", prompt: "帮我做一张校样流程卡，初校、复校、定稿三个阶段。初始初校，胶囊一下进入下一阶段，展开可以回到上一阶段。", before: "初校", after: "复校"),
        Sample(id: "packing-stock", prompt: "装盒余量现在有 12 枚，每装一盒扣 2 枚。做张小卡让我点胶囊直接装一盒，展开可以撤回一盒。", before: "12", after: "10"),
        Sample(id: "paper-mass", prompt: "做张纸张用量换算卡，每张纸重 3 克。初始张数是 4，在展开的卡里输入张数，点计算后显示总克数。", before: "12", after: "15", usesForm: true)
    ]

    // First-request tests deliberately leave presentation, history and undo unspecified.
    static let firstUseSamples = [
        Sample(id: "daily-water", prompt: "今天喝水帮我记一下，一瓶算一次，今天从零开始。", before: "0", after: "1"),
        Sample(id: "returned-books", prompt: "我在整理退回的图书，帮我记今天已经上架了几本，从零开始。", before: "0", after: "1"),
        Sample(id: "proof-progress", prompt: "校样依次要过初校、复校、定稿，帮我跟进到哪一步了。", before: "初校", after: "复校"),
        Sample(id: "print-weight", prompt: "我做版画，每张纸重3克，先按4张算。张数经常变，帮我随时换算总重量。", before: "12", after: "15", usesForm: true),
        Sample(id: "label-text", prompt: "我录入的货号大小写很乱，帮我把每次贴进来的货号统一转成大写，方便印标签。", before: "", after: "MINT-73A", usesForm: true)
    ]

    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["ORVLET_LATENCY_OUTPUT"] else { exit(2) }
        let folder = URL(fileURLWithPath: path)
        let repeats = Int(ProcessInfo.processInfo.environment["ORVLET_LATENCY_REPEATS"] ?? "1") ?? 1
        guard (1...10).contains(repeats) else { exit(2) }
        let selected = ProcessInfo.processInfo.environment["ORVLET_LATENCY_CASE"]
        var results: [[String: Any]] = []
        for round in 0..<repeats {
            let captures = repeats == 1 ? folder : folder.appendingPathComponent("round-" + String(round + 1))
            do { try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true) }
            catch { fputs("Could not create capture directory\n", stderr); exit(2) }
            var scheduled = samples.indices.map { samples[(round + $0) % samples.count] }
            if round == 0 || selected == "inspection" {
                scheduled.append(Sample(id: "inspection", prompt: "我在验收灯具，从零开始，每验过一盏就让我按一下记一盏，也能撤销刚才那次。", before: "0", after: "1"))
            }
            if selected == "first-use" || firstUseSamples.contains(where: { $0.id == selected }) {
                scheduled = firstUseSamples.indices.map { firstUseSamples[(round + $0) % firstUseSamples.count] }
            }
            for sample in scheduled where selected == nil || selected == "first-use" || selected == sample.id {
                var row = await measure(sample, captures)
                row["round"] = round + 1
                results.append(row)
                do {
                    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: folder.appendingPathComponent("results.json"), options: .atomic)
                } catch { fputs("Could not save live benchmark evidence\n", stderr); exit(2) }
                print("\(sample.id): \(row["error"] ?? row["effectSeconds"] ?? "unknown")")
            }
        }
        exit(!results.isEmpty && results.allSatisfy { $0["ok"] as? Bool == true } ? 0 : 1)
    }

    private static func measure(_ sample: Sample, _ folder: URL) async -> [String: Any] {
        let suite = "orvlet.live.card." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.interfaceLanguage = "简体中文"
        model.settings.reduceMotion = ProcessInfo.processInfo.environment["ORVLET_LATENCY_REDUCE_MOTION"] == "1"
        let delegate = AppDelegate(model: model)
        let screen = NSRect(x: -18500, y: -18500, width: 1600, height: 1100)
        let anchor = NSRect(origin: NSPoint(x: screen.midX, y: screen.midY), size: model.compactSize)
        let panel = ShellPanel(contentRect: anchor, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        delegate.panel = panel
        let host = NSHostingView(rootView: ContentView(model: model))
        panel.contentView = host
        model.onResize = { [weak delegate] size in delegate?.resize(to: size, in: screen) }
        delegate.resize(to: model.windowSize, in: screen)
        panel.orderBack(nil)
        model.selectChat(true)
        model.command = sample.prompt
        let clock = ContinuousClock()
        var start = clock.now
        func elapsed() -> Double {
            let c = start.duration(to: clock.now).components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
        var row: [String: Any] = ["id": sample.id, "prompt": sample.prompt,
            "model": model.settings.main.model, "decisionProviderEnabled": model.settings.useFast,
            "surface": sample.usesForm ? "expanded" : "capsule", "reducedMotion": model.motionReduced, "ok": false]
        defer {
            model.cancel()
            model.taskRuntime.stopAll()
            model.onResize = nil
            panel.orderOut(nil)
            Diagnostics.benchmarkEvents = nil
            defaults.removePersistentDomain(forName: suite)
        }
        do {
            guard model.settings.main.isConfigured else { throw AppError.message("No configured production model") }
            try await Task.sleep(for: .milliseconds(120))
            Diagnostics.benchmarkEvents = []
            start = clock.now
            model.sendCommand()
            var clicked = false
            var opened = false
            var lastCompact = ""
            var lastDetail = ""
            repeat {
                try await Task.sleep(for: .milliseconds(30))
                if elapsed() > 75 { throw AppError.message("75 s elapsed before a verified interaction") }
                guard let task = model.ambientTasks.first(where: { $0.taskSurface != nil }) else {
                    if !model.busy && elapsed() > 1 {
                        throw AppError.message("Request completed without a generated card")
                    }
                    continue
                }
                if row["committedSeconds"] == nil { row["committedSeconds"] = elapsed(); row["title"] = task.title }
                host.layoutSubtreeIfNeeded()
                if let compact = await visibleWeb(host, compact: true) {
                    lastCompact = await read(compact)
                }
                row["compactText"] = lastCompact
                if sample.usesForm && !opened {
                    guard let opener = tapTarget(host, id: task.id, shortcut: false) else { continue }
                    tap(opener, panel)
                    opened = true
                }
                if sample.usesForm {
                    guard let web = await visibleWeb(host, compact: false) else { continue }
                    lastDetail = await read(web)
                    row["detailText"] = lastDetail
                    if !clicked && (sample.before.isEmpty || containsValue(lastDetail, sample.before)) {
                        let changed = sample.id == "label-text" ? try await enterText("mint-73a", in: web) : try await web.evaluateJavaScript("""
                            (()=>{const input=[...document.querySelectorAll('input[data-field]')].find(e=>e.value==='4'); if(!input)return false; input.value='5'; input.dispatchEvent(new Event('input',{bubbles:true})); input.dispatchEvent(new Event('change',{bubbles:true})); const b=document.querySelector('button[data-action]'); if(b&&!b.disabled)b.click();return true})()
                            """) as? Bool == true
                        guard changed else { continue }
                        row["clickSeconds"] = elapsed()
                        clicked = true
                    } else if clicked && containsValue(lastDetail, sample.after) { break }
                } else if !clicked {
                    guard containsValue(lastCompact, sample.before), let target = tapTarget(host, id: task.id, shortcut: true) else {
                        if !model.busy && elapsed() > (row["committedSeconds"] as? Double ?? 0) + 4 {
                            throw AppError.message("Generated card has no hit-testable shortcut or matching initial reading")
                        }
                        continue
                    }
                    row["clickSeconds"] = elapsed()
                    tap(target, panel)
                    clicked = true
                } else if containsValue(lastCompact, sample.after) && !containsValue(lastCompact, sample.before) {
                    break
                }
            } while true
            row["effectSeconds"] = elapsed()
            row["stayedOffscreen"] = NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) } && !panel.isKeyWindow
            guard row["stayedOffscreen"] as? Bool == true else { throw AppError.message("Offscreen isolation failed") }
            if firstUseSamples.contains(where: { $0.id == sample.id }) {
                guard let compact = await visibleWeb(host, compact: true),
                      let layout = try await compact.evaluateJavaScript("""
                        (() => {
                          const line = document.querySelector('.calm-glance > span');
                          if (!line) return null;
                          const unit = line.querySelector('.preset-unit-suffix:not([hidden])');
                          return {width: line.clientWidth, content: line.scrollWidth,
                            unitRight: unit?.getBoundingClientRect().right || 0, viewport: innerWidth};
                        })()
                        """) as? [String: Double] else { throw AppError.message("Cannot measure the compact reading") }
                row["compactLayout"] = layout
                guard let width = layout["width"], let content = layout["content"], let unitRight = layout["unitRight"],
                      let viewport = layout["viewport"], width > 0, content <= width + 1, unitRight <= viewport + 1 else {
                    throw AppError.message("The compact reading or its unit is clipped at the actual capsule width")
                }
            }
            if !sample.usesForm {
                try await Task.sleep(for: .milliseconds(350))
                try await capture(panel, to: folder.appendingPathComponent(sample.id + "-capsule.png"))
                guard let task = model.ambientTasks.first(where: { $0.taskSurface != nil }),
                      let opener = tapTarget(host, id: task.id, shortcut: false) else {
                    throw AppError.message("Capsule detail did not expose its opening control")
                }
                tap(opener, panel)
            }
            for _ in 0..<100 {
                if let web = await visibleWeb(host, compact: false) {
                    let detail = await read(web)
                    if detail.contains(sample.after), !model.collapsed { row["detailText"] = detail; break }
                }
                try await Task.sleep(for: .milliseconds(35))
            }
            guard let detail = row["detailText"] as? String, containsValue(detail, sample.after) else {
                throw AppError.message("Expanded view did not render the changed value")
            }
            try await Task.sleep(for: .milliseconds(400))
            try await capture(panel, to: folder.appendingPathComponent(sample.id + "-detail.png"))
            if !sample.usesForm {
                guard let web = await visibleWeb(host, compact: false),
                      let task = model.ambientTasks.first(where: { $0.taskSurface != nil }),
                      let surface = task.taskSurface,
                      let primary = surface.actions.first(where: { $0.compactLabel != nil }) else {
                    throw AppError.message("Generated form has no primary action to compare with its detail controls")
                }
                if sample.id == "daily-water" || sample.id == "returned-books" {
                    func journalRows() async throws -> [String] {
                        try await web.evaluateJavaScript("[...document.querySelectorAll('.calm-journal-row')].filter(e=>e.offsetHeight>0).map(e=>e.innerText)") as? [String] ?? []
                    }
                    let rows = try await journalRows()
                    guard rows.count == 1, Self.hasRecentTime(in: rows[0], near: Date()) else {
                        throw AppError.message("The first recorded action has no current time in the expanded card")
                    }
                    guard !detail.contains("Recent entries"), !detail.contains("Undo last") else {
                        throw AppError.message("Host journal controls ignored the Chinese interface setting")
                    }
                    row["timestampVerified"] = true
                    if sample.id == "daily-water" {
                        for expected in 2...11 {
                            try await pressDetail(web, matching: primary.id, other: false, expecting: String(expected))
                        }
                        let recent = try await journalRows()
                        guard (1...3).contains(recent.count), recent.allSatisfy({ Self.hasRecentTime(in: $0, near: Date()) }) else {
                            throw AppError.message("Eleven actions did not produce a bounded list of recent timed entries")
                        }
                        row["recentRowsAtEleven"] = recent
                        try await capture(panel, to: folder.appendingPathComponent(sample.id + "-eleven.png"))
                        try await pressDetail(web, matching: "undoJournal", other: false, expecting: "10")
                    } else {
                        try await pressDetail(web, matching: "undoJournal", other: false, expecting: sample.before)
                        guard try await journalRows().isEmpty else { throw AppError.message("Undone entry is still visible") }
                    }
                    row["secondaryVerified"] = true
                }
                if sample.id == "proof-progress" {
                    let steps = try await web.evaluateJavaScript("[...document.querySelectorAll('.calm-sequence li')].map(e=>e.textContent.trim())") as? [String] ?? []
                    let current = try await web.evaluateJavaScript("document.querySelector('.calm-sequence [aria-current=step]')?.textContent.trim()") as? String
                    guard steps == ["初校","复校","定稿"], current == sample.after else {
                        throw AppError.message("The expanded workflow did not highlight its place in the supplied sequence")
                    }
                    row["workflowContextVerified"] = true
                }
                if sample.id == "proof-stages" || sample.id == "proof-progress" {
                    try await pressDetail(web, matching: primary.id, other: false, expecting: "定稿")
                    try await pressDetail(web, matching: primary.id, other: true, expecting: sample.after)
                }
                if row["secondaryVerified"] == nil {
                    try await pressDetail(web, matching: primary.id, other: true, expecting: sample.before)
                    row["secondaryVerified"] = true
                }
            } else if sample.id == "print-weight" {
                let web = await visibleWeb(host, compact: false)
                let fields = try await web?.evaluateJavaScript("[...document.querySelectorAll('input[data-field]')].filter(e=>e.offsetHeight>0).map(e=>e.value)") as? [String] ?? []
                guard fields.contains("5"), detail.contains("克") || detail.contains("g") else {
                    throw AppError.message("Calculator omitted the editable paper count or result unit")
                }
                row["formulaVerified"] = true
            } else if sample.id == "label-text" {
                guard let web = await visibleWeb(host, compact: false), try await enterText("ivORy-4b", in: web) else {
                    throw AppError.message("Text transformer is not editable after its first conversion")
                }
                for _ in 0..<60 {
                    if (await read(web)).contains("IVORY-4B") { row["secondConversionVerified"] = true; break }
                    try await Task.sleep(for: .milliseconds(35))
                }
                guard row["secondConversionVerified"] as? Bool == true else {
                    throw AppError.message("A different mixed-case item did not produce its uppercase label")
                }
            }
            row["ok"] = true
        } catch {
            row["error"] = error.localizedDescription
            row["windowSize"] = [panel.frame.width, panel.frame.height]
            row["requestedSize"] = [model.windowSize.width, model.windowSize.height]
            try? await capture(panel, to: folder.appendingPathComponent(sample.id + "-failure.png"))
        }
        row["trialSeconds"] = elapsed()
        row["trace"] = (Diagnostics.benchmarkEvents ?? []).map { e in
            e.filter { ["event", "stage", "name", "model", "seconds", "tools", "promptBytes", "toolBytes", "category"].contains($0.key) }
        }
        return row
    }

    private static func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }

    private static func tapTarget(_ root: NSView, id: UUID, shortcut: Bool) -> WindowDragArea.DragView? {
        children(root).compactMap { $0 as? WindowDragArea.DragView }.first { view in
            guard view.identifier?.rawValue == id.uuidString, view.enabled, view.onClick != nil,
                  (shortcut ? view.bounds.width <= 45 : view.bounds.width > 45), !view.isHiddenOrHasHiddenAncestor else { return false }
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root.superview)
            return root.hitTest(center) === view
        }
    }

    private static func tap(_ view: NSView, _ window: NSWindow) {
        let click = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: click, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
        }
    }

    private static func hasRecentTime(in text: String, near date: Date) -> Bool {
        for delta in [0, -60] {
            let time = Calendar.current.dateComponents([.hour, .minute], from: date.addingTimeInterval(Double(delta)))
            guard let hour = time.hour, let minute = time.minute else { continue }
            for displayHour in [hour, hour % 12 == 0 ? 12 : hour % 12] {
                let pattern = "(?<![0-9])0?" + String(displayHour) + "[:：]" + String(format: "%02d", minute) + "(?![0-9])"
                if text.range(of: pattern, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    private static func containsValue(_ text: String, _ value: String) -> Bool {
        guard Int(value) != nil else { return text.contains(value) }
        return text.range(of: "(?<![0-9])" + value + "(?![0-9])", options: .regularExpression) != nil
    }

    private static func read(_ web: WKWebView) async -> String {
        (try? await web.evaluateJavaScript("document.getElementById('surface')?.innerText || ''")) as? String ?? ""
    }

    private static func enterText(_ text: String, in web: WKWebView) async throws -> Bool {
        let quoted = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        return try await web.evaluateJavaScript("""
            (() => {
              const input=document.querySelector('input[type=text][data-field],textarea[data-field]');
              if(!input)return false;
              input.value=\(quoted);
              input.dispatchEvent(new Event('input',{bubbles:true}));
              input.dispatchEvent(new Event('change',{bubbles:true}));
              const action=document.querySelector('button[data-action]');
              if(action && !action.disabled)action.click();
              return true;
            })()
            """) as? Bool == true
    }

    private static func visibleWeb(_ root: NSView, compact: Bool) async -> WKWebView? {
        for web in children(root).compactMap({ $0 as? WKWebView }) where web.bounds.width > 0 && !web.isHiddenOrHasHiddenAncestor {
            if (try? await web.evaluateJavaScript("window.isCompact")) as? Bool == compact { return web }
        }
        return nil
    }

    private static func pressDetail(_ web: WKWebView, matching primary: String, other: Bool, expecting: String) async throws {
        let quoted = String(decoding: try JSONEncoder().encode(primary), as: UTF8.self)
        let condition = other ? "!==" : "==="
        let script = "(()=>{const b=[...document.querySelectorAll('button[data-action]')].find(b=>b.offsetWidth && !b.disabled && b.dataset.action" + condition + quoted + ");if(!b)return false;b.click();return true})()"
        guard try await web.evaluateJavaScript(script) as? Bool == true else {
            throw AppError.message("Expanded card is missing a requested action")
        }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(35))
            let result = (try? await web.evaluateJavaScript("document.querySelector('.calm-result [data-bind], strong[data-bind], [data-bind]')?.innerText || ''")) as? String ?? ""
            if containsValue(result, expecting) { return }
        }
        throw AppError.message("Expanded action did not show the requested result " + expecting)
    }

    private static func capture(_ window: NSWindow, to url: URL) async throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AppError.message("Could not capture rendered shell")
        }
        var layers: [(WKWebView, NSImage, NSRect)] = []
        for web in children(view).compactMap({ $0 as? WKWebView }) where web.bounds.width > 1 && web.bounds.height > 1 {
            let rect = web.convert(web.bounds, to: view)
            guard view.bounds.contains(rect), !web.isHiddenOrHasHiddenAncestor,
                  let shot = try? await web.takeSnapshot(configuration: nil) else { continue }
            let y = view.isFlipped ? view.bounds.height - rect.maxY : rect.minY
            layers.append((web, shot, NSRect(x: rect.minX, y: y, width: rect.width, height: rect.height)))
        }
        // AppKit may cache the previous WebKit frame. Capture the native background
        // separately, then composite each fresh transparent webpage exactly once.
        for (web, _, _) in layers { web.isHidden = true }
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        for (web, _, _) in layers { web.isHidden = false }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        image.lockFocus()
        for (_, layer, rect) in layers { layer.draw(in: rect) }
        image.unlockFocus()
        guard let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        else { throw AppError.message("Could not encode rendered shell") }
        try data.write(to: url)
    }
}
#endif
