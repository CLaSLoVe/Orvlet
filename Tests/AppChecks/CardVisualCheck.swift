#if DEBUG
import AppKit
import WebKit

@MainActor
enum CardVisualCheck {
    static func run() async throws {
        var spec = APIDataSpec(url: "https://example.org/room", fields: [
            .init(key: "temperature", label: "Temperature", pointer: "/latest", unit: "°C"),
            .init(key: "minutes", label: "Minutes", pointer: "/samples", itemPointer: "/time"),
            .init(key: "readings", label: "Temperature", pointer: "/samples", itemPointer: "/value"),
        ])
        spec.card = .init(kind: .reading, primaryKey: "temperature", subject: "Studio")
        let markup = CardMarkup(html: """
            <section class='calm-surface'><strong class='calm-value'><span data-bind='temperature'></span> °C</strong>
            <figure data-series='readings' data-x='minutes' aria-label='Temperature (°C) over minutes'></figure>
            <table><thead><tr><th data-column='minutes'>Minute</th><th data-column='readings'>Temperature (°C)</th></tr></thead></table></section>
            """, compactHTML: "", css: "", height: 300)
        let samples: [[String: Any]] = [["time": 0, "value": 19], ["time": 5, "value": 21], ["time": 20, "value": NSNull()], ["time": 30, "value": 22]]
        let service = APIDataService(code: TaskCodeRuntime(), fetch: { _ in ["latest": 22, "samples": samples] })
        spec.visuals = [
            .init(kind: .line, label: "Temperature (°C) over minutes", columns: [.init(key: "minutes", label: "Minute"), .init(key: "readings", label: "Temperature (°C)")]),
            .init(kind: .table, label: "Observations", columns: [.init(key: "minutes", label: "Minute"), .init(key: "readings", label: "Temperature (°C)")]),
        ]
        // Exercise the ordinary tool contract and publication path with bad model output.
        var source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String: Any]
        let validTable = (source["visuals"] as! [[String: Any]])[1]
        source["visuals"] = [
            ["kind": "line", "columns": [" MINUTES ", "readings"]],
            ["kind": "line", "label": "Trend", "columns": ["readings", "readings"]],
            ["kind": "line", "columns": ["minutes", "absent"]],
            ["kind": "unknown"],
            validTable
        ]
        var calls = 0
        let suite = "orvlet.visuals." + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: store)
        model.isLiveTest = true
        model.persistHistory = false
        defer {
            model.dataRefreshTimer?.invalidate()
            model.adaptive.invalidate()
            model.browser.dispose()
            store.removePersistentDomain(forName: suite)
        }
        model.settings.interfaceLanguage = "English"
        model.apiData = APIDataService(code: model.taskCode, fetch: { _ in
            calls += 1
            return ["latest": 21 + calls, "samples": samples]
        })
        let id = UUID()
        model.beginAmbientRequest("看一下工作室的温度", taskID: id)
        model.agent.nativeRequestActive = true
        model.agent.activeTaskID = id
        let result = try await model.agent.execute("query_api", ["title": "Studio", "source": source])
        guard result["verified"] as? Bool == true, calls == 1,
            let task = model.sideTasks.first(where: { $0.id == id }),
            let blocks = task.taskSurface?.apiData?.visuals, blocks.count == 2,
            blocks[0].kind == .line, blocks[0].columns.map(\.key) == ["minutes", "readings"],
            blocks[1].kind == .table, task.state["temperature"] == "22",
            task.presentation.compactHTML.contains("Studio"),
            CardMarkup.bindingKeys(in: task.presentation.compactHTML).contains("temperature"),
            CardMarkup.bindingKeys(in: task.presentation.html).contains("temperature")
        else { throw AppError.message("A defective optional chart interrupted a verified reading or its valid sibling") }
        guard let refresh = model.refreshAPIData(id) else { throw AppError.message("Recovered card could not refresh") }
        await refresh.value
        guard calls == 2, model.sideTasks.first(where: { $0.id == id })?.state["temperature"] == "23" else {
            throw AppError.message("Recovered card did not refresh its shared reading")
        }
        source["expectations"] = ["temperature": "100"]
        do {
            _ = try await model.agent.execute("query_api", ["title": "Studio", "source": source])
            throw AppError.message("Incorrect source evidence was published")
        } catch {
            guard (error as? ToolArgumentError)?.path == "$.source.expectations.temperature",
                model.sideTasks.first(where: { $0.id == id })?.state["temperature"] == "23" else { throw error }
        }
        model.agent.nativeRequestActive = false
        model.finishAmbientRequest()
        let state = try await service.read(spec)
        let custom = try spec.surface(title: "Studio", state: state, proposed: markup)
        let card = try spec.surface(title: "Studio", state: state)
        guard custom.apiData?.customLayout == true, card.markup.compactHTML.contains("Studio"),
            CardMarkup.bindingKeys(in: card.markup.compactHTML).contains("temperature") else {
            throw AppError.message("Expanded design or shared capsule binding was lost")
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 330))
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        defer { window.orderOut(nil) }
        web.loadHTMLString(HTMLCardView.document(fragment: card.markup.html, css: card.markup.css, language: "en-GB"), baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof updateCard === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        func render(_ state: [String: String], compact: Bool = false) async throws {
            _ = try await web.evaluateJavaScript("updateCard(" + JSONText.encode(HTMLCardView.renderState(state, compact: compact)) + "); true")
        }
        _ = try await web.evaluateJavaScript("const probe=document.createElement('span');probe.dataset.bind='compact';document.body.append(probe);true")
        try await render(["compact": "13 min"])
        guard (try await web.evaluateJavaScript("!window.isCompact && probe.textContent==='13 min'")) as? Bool == true else {
            throw AppError.message("Window mode replaced a reading with the same name")
        }
        _ = try await web.evaluateJavaScript("probe.remove();true")
        try await render(card.state)
        let layout = try await web.evaluateJavaScript("""
            document.querySelectorAll('tbody tr').length === 4 &&
            document.querySelectorAll('tbody tr')[2].cells[1].textContent === '—' &&
            document.querySelector('figure path').getAttribute('d').includes('M273,') &&
            document.querySelector('figure').getBoundingClientRect().width <= 300 &&
            document.querySelector('table').scrollWidth <= 300
            """)
        guard layout as? Bool == true else { throw AppError.message("Table or chart did not render observed values and gap") }
        if let path = ProcessInfo.processInfo.environment["ORVLET_CARD_SNAPSHOT"] {
            let snapshot = try await web.takeSnapshot(configuration: nil)
            guard let tiff = snapshot.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw AppError.message("Could not capture rendered card")
            }
            try png.write(to: URL(fileURLWithPath: path))
        }
        _ = try await web.evaluateJavaScript("document.querySelector('figure').dataset.xFormat='unixSeconds';true")
        var dated = card.state
        dated["minutes"] = "[1704067200,1704153600]"
        dated["readings"] = "[19,22]"
        try await render(dated)
        guard try await web.evaluateJavaScript("""
            document.documentElement.lang==='en-GB' && document.querySelector('.visual-range span').textContent ===
            new Date(1704067200000).toLocaleString('en-GB',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'})
            """) as? Bool == true else { throw AppError.message("Chart labels ignored the requested interface language") }
        _ = try await web.evaluateJavaScript("document.querySelector('figure').dataset.xFormat='number';true")
        var updated = card.state
        updated["temperature"] = "24"
        updated["minutes"] = "[0,30]"
        updated["readings"] = "[19,24]"
        try await render(updated)
        guard try await web.evaluateJavaScript("document.querySelectorAll('tbody tr').length===2 && document.querySelector('tbody tr:last-child td:last-child').textContent==='24' && document.querySelector('[data-bind=temperature]').textContent==='24'") as? Bool == true else {
            throw AppError.message("A refreshed series or table kept stale cells")
        }
        let glance = "<div class='calm-glance'><small class='calm-label'>Edit</small><span><strong class='calm-value' data-bind='left'></strong>" + CardMarkup.unitSuffix("min") + "</span></div>"
        var otherInstance = CardMarkup(html: markup.html, compactHTML: glance, css: "body{display:none!important}")
        otherInstance.bindReusedGlanceTitle()
        web.loadHTMLString(HTMLCardView.document(fragment: otherInstance.compactHTML, css: otherInstance.css), baseURL: nil)
        // Wait for this specific document rather than the outgoing WebKit page.
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.querySelector('[data-bind=left]')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await render(["title": "North Pier", "left": "17 min left"], compact: true)
        guard try await web.evaluateJavaScript("document.querySelector('.calm-label').innerText==='North Pier' && document.body.getBoundingClientRect().height>0 && document.querySelector('.preset-unit-suffix').hidden && document.querySelector('#surface').innerText.includes('17 min left')") as? Bool == true else {
            throw AppError.message("Expanded CSS hid the host capsule, or a formatted result repeated its unit")
        }
    }
}
#endif
