#if DEBUG
    import Foundation
    import AppKit
    import WebKit

    @MainActor
    enum APIDataCheck {
        static func currency() -> APIDataSpec {
            APIDataSpec(
                url: "https://api.frankfurter.dev/v2/rate/{fromCurrency}/{toCurrency}",
                fields: [
                    APIDataField(key: "base", label: "From", pointer: "/base"),
                    APIDataField(key: "quote", label: "To", pointer: "/quote"),
                    APIDataField(key: "rate", label: "Reference rate", pointer: "/rate"),
                ], updatedAtPointer: "/date", inputs: ["amount": "56", "fromCurrency": "HKD", "toCurrency": "CNY"],
                controls: [
                    APIDataControl(key: "amount", label: "Amount", kind: "number"),
                    APIDataControl(
                        key: "fromCurrency", label: "From", kind: "select", options: ["HKD", "USD", "EUR", "CNY"]),
                    APIDataControl(
                        key: "toCurrency", label: "To", kind: "select", options: ["CNY", "HKD", "USD", "EUR"]),
                ],
                calculation:
                    "const value=Number(input.amount)*Number(state.rate); if(!Number.isFinite(value))throw Error('Invalid amount'); return {state:{converted:value.toFixed(2)}};",
                outputs: [APIDataOutput(key: "converted", label: "Result", unitKey: "quote")],
                expectations: ["base": "{fromCurrency}", "quote": "{toCurrency}"], maxAgeSeconds: 432000)
        }
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            let hints = APIDataService.Reading(
                state: [:],
                response: [
                    "a/b": [["name": "Example", "other": "Different"]], "region": "Example",
                ])
            try check(
                hints.candidatePointers { $0 == "Example" } == ["/a~1b/0/name", "/region"],
                "Source repair hints retain exact escaped paths and array indices from the fetched response")
            try check(
                hints.candidatePointers { $0 == "Absent" }.isEmpty,
                "Source repair hints cannot fabricate missing identity evidence")
            let many = APIDataService.Reading(state: [:], response: Array(repeating: "Example", count: 100))
            try check(
                many.candidatePointers { $0 == "Example" }.count == 8,
                "Source repair hints stay bounded even for broad responses")
            var mixed = currency()
            mixed.card = DataCardPreset(kind: .currency, primaryKey: "rate")
            let mixedValidated = try mixed.validated()
            try check(
                mixedValidated.displayRows.map(\.key) == ["rate", "converted"],
                "A source primary and calculated secondary share the same validation and display contract")
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            defer {
                for task in model.sideTasks { model.stopTaskActions(task.id) }
                model.adaptive.invalidate()
                model.browser.dispose()
                model.taskClock?.invalidate()
            }
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            var payload: [String: Any] = ["date": today, "base": "HKD", "quote": "CNY", "rate": 0.85]
            var fetches = 0
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { _ in
                    fetches += 1
                    return payload
                })
            let spec = currency()
            let values = try await model.apiData.read(currency())
            try check(
                values["converted"] == "47.60" && values["sourceDate"] == "Data as of " + today,
                "API conversion uses the fetched rate and source date, not a model constant")
            let invalid = CardMarkup(html: "<script>bad()</script>", compactHTML: "", css: "")
            let surface = try spec.surface(title: "Currency conversion", state: values, proposed: invalid)
            try check(
                surface.fields.count == 3 && surface.markup.html.contains("data-field='amount'")
                    && surface.markup.html.contains("sourceDate") && surface.markup.html.contains("refreshData")
                    && surface.markup.compactHTML.contains("converted"),
                "Invalid generated styling falls back to a bound result with source, date and refresh")
            let unwired = CardMarkup(
                html: surface.markup.html.replacingOccurrences(of: "data-input='updateData'", with: "")
                    .replacingOccurrences(of: "data-change='updateData'", with: ""),
                compactHTML: surface.markup.compactHTML, css: surface.markup.css)
            let rewired = try spec.surface(title: "Currency conversion", state: values, proposed: unwired)
            try check(
                rewired.markup.html.contains("data-input='updateData'")
                    && rewired.markup.html.contains("data-change='updateData'"),
                "Generated layouts receive host-managed input behavior without another model call")
            let restored = try JSONDecoder().decode(TaskSurface.self, from: JSONEncoder().encode(surface))
            try check(
                restored.apiData?.url == spec.url && restored.actions.first?.kind == .remote,
                "Saved data cards retain their acquisition and calculation method")
            let owner = UUID()
            model.publishTaskSurface(surface, id: owner)
            model.refreshAPIData(owner, fields: ["amount": "100"], force: false)
            await model.taskActionJobs[owner]?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "85.00" && fetches == 1,
                "Editing a local parameter recalculates immediately without a model or API request")
            model.refreshAPIData(owner, fields: ["amount": ""], force: false)
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "—" && model.sideTasks.first?.dataIssue == nil,
                "An incomplete input clears the answer and asks for a value without a task failure")
            model.refreshAPIData(owner, fields: ["amount": "56"], force: false)
            await model.taskActionJobs[owner]?.value
            payload["rate"] = 0.9
            model.refreshAPIData(owner)
            await model.taskActionJobs[owner]?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "50.40" && fetches == 2,
                "Refreshing a card fetches and recalculates directly without the model or a browser")
            payload["base"] = "USD"
            payload["rate"] = 7
            model.refreshAPIData(owner, fields: ["fromCurrency": "USD"], force: false)
            await model.taskActionJobs[owner]?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "392.00" && fetches == 3
                    && model.sideTasks.first?.liveValues?["sourceRequest"]?.hasSuffix("USD/CNY") == true,
                "Changing a source parameter requests the new API URL and verifies its actual returned identity")
            model.refreshAPIData(owner, fields: ["fromCurrency": "HKD"], force: false)
            await model.taskActionJobs[owner]?.value
            model.refreshAPIData(owner)
            await model.taskActionJobs[owner]?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "392.00" && model.sideTasks.first?.dataIssue != nil,
                "An incorrect source identity preserves the last value and marks it unavailable instead of claiming success"
            )
            payload["base"] = "HKD"
            payload["date"] = "2000-01-01"
            var rejected = false
            do { _ = try await model.apiData.read(spec) } catch { rejected = true }
            try check(rejected, "A newly fetched but outdated API response cannot satisfy the freshness bound")
            payload["date"] = today
            payload.removeValue(forKey: "rate")
            rejected = false
            do { _ = try await model.apiData.read(spec) } catch { rejected = true }
            try check(rejected, "Missing API fields fail validation instead of silently yielding a plausible number")
            for raw in [
                "http://example.com/data", "https://127.0.0.1/data", "https://localhost/data",
                "https://" + "user:pass" + "@example.com/data", "https://example.com/data?api_key=synthetic",
            ] {
                rejected = false
                do { _ = try PublicDataClient.url(raw) } catch { rejected = true }
                try check(rejected, "Public API transport rejects private, insecure or credential-bearing URL")
            }
            // Applicability and publication are independent for every data source.
            let instant = APIDataSpec.timestamp("2026-11-05T12:00:00Z")!
            var datedPayload: [String: Any] = [
                "published": "2026-11-05T11:30:00Z",
                "periods": [["date": "2026-11-07", "value": 23]],
            ]
            let datedService = APIDataService(code: model.taskCode, fetch: { _ in datedPayload }, now: { instant })
            var datedSpec = APIDataSpec(
                url: "https://example.org/series",
                fields: [
                    APIDataField(key: "period", label: "Period", pointer: "/periods/{index}/date"),
                    APIDataField(key: "reading", label: "Value", pointer: "/periods/{index}/value"),
                ],
                updatedAtPointer: "/published", inputs: ["index": "0"],
                expectations: ["period": "2026-11-07"], maxAgeSeconds: 3600)
            let forecast = try await datedService.read(datedSpec)
            try check(
                forecast["period"] == "2026-11-07",
                "Future applicability passes with a fresh independent publication time")
            datedPayload["published"] = "2026-11-01T11:30:00Z"
            rejected = false
            do { _ = try await datedService.read(datedSpec) } catch { rejected = !(error is ToolArgumentError) }
            try check(rejected, "Future coverage cannot conceal an outdated publication")
            datedPayload["published"] = "2026-11-07T11:30:00Z"
            rejected = false
            do { _ = try await datedService.read(datedSpec) } catch let error as ToolArgumentError {
                rejected = error.issue.contains("future")
            }
            try check(rejected, "A future publication pointer is a repairable semantic error, not stale data")
            datedPayload["published"] = "not a date"
            rejected = false
            do { _ = try await datedService.read(datedSpec) } catch let error as ToolArgumentError {
                rejected = error.issue.contains("parsed")
            }
            try check(rejected, "An unsupported timestamp reports a format problem rather than an age problem")
            datedPayload["published"] = "2026-11-05 07:30 PM"
            datedSpec.updatedAtFormat = "yyyy-MM-dd hh:mm a"
            datedSpec.updatedAtTimeZone = "Asia/Hong_Kong"
            let localTime = try await datedService.read(datedSpec)
            try check(
                datedService.canReuse(datedSpec, state: localTime, fetchedAt: instant),
                "Acquisition and reuse parse documented local source time identically")
            datedSpec.updatedAtFormat = nil
            datedSpec.updatedAtTimeZone = nil
            datedSpec.updatedAtPointer = "/updates/{index}"
            datedPayload["updates"] = ["2026-11-05T11:30:00Z"]
            _ = try await datedService.read(datedSpec)
            checks.append("Timestamp pointers expand the same parameters as value pointers")
            var misbound = datedSpec
            misbound.fields[0].pointer = "/periods/0/value"
            var bindingRepair = false
            do { _ = try await datedService.read(misbound) } catch let error as ToolArgumentError {
                bindingRepair = error.issue.replacingOccurrences(of: "\\/", with: "/").contains("/periods/0/date")
            }
            try check(
                bindingRepair,
                "Declared source expectations expose same-response binding repairs without accepting mismatched values")
            datedSpec.inputs?["period"] = "2026-11-07"
            let echo = try await datedService.read(datedSpec)
            try check(
                echo["period"] == "2026-11-07",
                "A query parameter may share a source key only after its returned value is verified")
            datedSpec.inputs?["period"] = "2026-11-08"
            rejected = false
            do { _ = try await datedService.read(datedSpec) } catch { rejected = true }
            try check(rejected, "A requested input cannot overwrite a conflicting fetched identity")
            rejected = false
            do { _ = try await datedService.calculate(datedSpec, state: echo) } catch { rejected = true }
            try check(rejected, "Cached recalculation preserves the same input/source identity boundary")
            datedSpec.inputs?.removeValue(forKey: "period")
            datedSpec.expectations = ["period": "2026-11-08"]
            rejected = false
            do { _ = try await datedService.read(datedSpec) } catch { rejected = true }
            try check(rejected, "Fresh data for the wrong requested period is rejected")
            datedSpec.updatedAtPointer = nil
            rejected = false
            do { _ = try datedSpec.validated() } catch is ToolArgumentError { rejected = true }
            try check(rejected, "A freshness bound without publication evidence fails before transport")

            let weather = APIDataSpec(
                url: "https://api.open-meteo.com/v1/forecast",
                fields: [APIDataField(key: "temperature", label: "Temperature °C", pointer: "/current/temperature_2m")],
                updatedAtPointer: "/current/time")
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { _ in ["current": ["time": today + "T12:00:00Z", "temperature_2m": 24.5]] })
            let observed = try await model.apiData.read(weather)
            try check(
                observed["temperature"] == "24.5" && observed["sourceDate"]?.contains("12:00") == true,
                "The same generic API reader handles nested weather data with its own source time")
            var editableWeather = weather
            editableWeather.url =
                "https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}&current=temperature_2m"
            editableWeather.inputs = ["latitude": "22.3", "longitude": "114.2"]
            editableWeather.controls = [
                APIDataControl(key: "latitude", label: "Latitude", kind: "number"),
                APIDataControl(key: "longitude", label: "Longitude", kind: "number"),
            ]
            let weatherID = UUID()
            model.publishTaskSurface(
                try editableWeather.surface(title: "Weather", state: try await model.apiData.read(editableWeather)),
                id: weatherID)
            var weatherURL = ""
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { url in
                    weatherURL = url
                    return ["current": ["time": today + "T12:00:00Z", "temperature_2m": 18.2]]
                })
            model.refreshAPIData(weatherID, fields: ["latitude": "35.6"], force: false)
            await model.taskActionJobs[weatherID]?.value
            try check(
                weatherURL.contains("latitude=35.6")
                    && model.sideTasks.first(where: { $0.id == weatherID })?.liveValues?["temperature"] == "18.2",
                "The same editable-parameter mechanism changes a weather query and updates nested source data without a currency-specific branch"
            )
            try check(
                APIDataSpec.scalar(APIDataSpec.value("/items/0/a~1b", in: ["items": [["a/b": 12]]])) == "12",
                "JSON pointers support arrays and escaped keys")
            var invalidCode = spec
            invalidCode.calculation = "throw new Error('Invalid arithmetic');"
            var codeRepair = false
            do {
                _ = try await model.apiData.calculate(
                    invalidCode, state: ["base": "HKD", "quote": "CNY", "rate": "0.85"])
            } catch let error as ToolArgumentError { codeRepair = error.path == "$.source.calculation" }
            try check(
                codeRepair,
                "Pure generated calculation errors are repaired as arguments, not retried as external failures")
            // Full agent execution: no navigation, no redundant finish round and no reset of another task.
            payload = ["date": today, "base": "HKD", "quote": "CNY", "rate": 0.85]
            model.apiData = APIDataService(code: model.taskCode, fetch: { _ in payload })
            model.agent.interpretationOverride = { _ in
                RequestIntent(
                    requiresFreshData: true, kind: .general,
                    requirements: [
                        OutcomeRequirement(label: "base currency", anyOf: ["HKD"]),
                        OutcomeRequirement(label: "quote currency", anyOf: ["CNY"]),
                        OutcomeRequirement(label: "Amount", anyOf: ["56"], inputKey: "amount"),
                    ], route: .api)
            }
            var rounds = 0
            var receivedBindingHint = false
            model.agent.completionOverride = { turns in
                rounds += 1
                if rounds == 2 {
                    let feedback = turns.last(where: { $0["role"] as? String == "tool" })?["content"] as? String ?? ""
                    receivedBindingHint =
                        feedback.contains("$.source.fields")
                        && feedback.replacingOccurrences(of: "\\/", with: "/").contains("/quote")
                }
                var echoed = spec
                if rounds == 1 {
                    echoed.fields[1].pointer = "/base"
                    echoed.expectations?.removeValue(forKey: "quote")
                }
                echoed.fields.append(APIDataField(key: "baseEcho", label: "Base echo", pointer: "/base"))
                let input: [String: Any] = [
                    "title": "Currency conversion",
                    "source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(echoed)),
                    "outcomeEvidence": [["requirement": 1, "fieldKey": "quote"]],
                ]
                return [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": "api-result", "type": "function",
                            "function": ["name": "query_api", "arguments": JSONText.encode(input)],
                        ]
                    ],
                ]
            }
            let browser = model.browser
            let reply = try await model.agent.run("Convert 56 HKD to CNY")
            try check(
                rounds == 2 && receivedBindingHint && reply.contains("47.60") && model.browser === browser
                    && model.webURL.isEmpty,
                "API execution repairs a source binding using same-response hints, accepts duplicate echoes and never opens a webpage"
            )
            // Generic webpage fallback: actual values in inputs/selects, not XE-specific selectors.
            let web = AppModel()
            web.isLiveTest = true
            web.persistHistory = false
            web.settings.autoAdapt = false
            defer {
                web.adaptive.invalidate()
                web.browser.dispose()
                web.taskClock?.invalidate()
            }
            _ = try await web.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/data-form"])
            let page = try await web.observation()
            let readings = page["readables"] as? [[String: Any]] ?? []
            try check(
                readings.contains(where: {
                    $0["selector"] as? String == "#base" && $0["text"] as? String == "HKD"
                        && $0["evidenceRole"] as? String == "selected"
                })
                    && readings.contains(where: {
                        $0["selector"] as? String == "#converted" && $0["text"] as? String == "47.60"
                    }), "Web fallback reads selected currency and readonly input results as actual source values")
            try check(
                !readings.contains(where: { $0["selector"] as? String == "#private" }),
                "Form result extraction never includes password inputs")
            web.upsertWebTask(.webpage)
            let webID = web.browser.id
            web.agent.interpretationOverride = { _ in
                RequestIntent(
                    kind: .general, needsBrowserContext: true,
                    requirements: [
                        OutcomeRequirement(label: "base currency", anyOf: ["HKD"]),
                        OutcomeRequirement(label: "quote currency", anyOf: ["CNY"]),
                    ], route: .web)
            }
            web.agent.completionOverride = { _ in
                @MainActor func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
                    [
                        "id": UUID().uuidString, "type": "function",
                        "function": ["name": name, "arguments": JSONText.encode(args)],
                    ]
                }
                return [
                    "role": "assistant",
                    "tool_calls": [
                        call(
                            "compose_ui",
                            [
                                "markup": ["html": "<script>invalid()</script>", "compactHTML": "", "css": ""],
                                "readings": [], "actions": [],
                            ]),
                        call(
                            "finish",
                            [
                                "outcome": "page_ready", "source_only": true, "reply": "56 HKD = 47.60 CNY",
                                "readings": [
                                    ["key": "base", "selector": "#base"], ["key": "quote", "selector": "#quote"],
                                    ["key": "converted", "selector": "#converted"],
                                ],
                                "outcomeEvidence": [
                                    ["requirement": 0, "readingKey": "base", "valueKey": "converted"],
                                    ["requirement": 1, "readingKey": "quote", "valueKey": "converted"],
                                ],
                            ]),
                    ],
                ]
            }
            let fallbackReply = try await web.agent.run("Convert 56 HKD to CNY", taskID: webID)
            try check(
                fallbackReply.contains("47.60") && web.hasCustomSurface && !web.taskFailed,
                "A styling error cannot discard a separately verified source result; the host supplies a bound fallback card"
            )
            try await web.browser.bindReadings(web.surface.readings ?? [])
            let changed =
                try await web.browser.webView.evaluateJavaScript(
                    "document.getElementById('converted').value='50.40';window.__orvlet.state().readings.converted")
                as? String
            try check(changed == "50.40", "Web fallback input readings update in place without freezing copied text")
            return checks
        }
        static func live(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            do {
                if CommandLine.arguments.contains("--agent-api") {
                    model.messages = []
                    model.sideTasks = []
                    model.settings.useFast = false
                    let started = Date()
                    let reply = try await model.agent.run("56港币等于多少人民币？用最新可获取的参考汇率，注明数据日期。")
                    let card = model.sideTasks.first(where: { $0.taskSurface?.apiData != nil })
                    let editable =
                        card?.taskSurface?.apiData?.inputControls.contains(where: { $0.kind == "number" }) == true
                    print(
                        JSONText.encode([
                            "ok": card != nil && editable, "seconds": Date().timeIntervalSince(started), "reply": reply,
                            "usedAPI": card != nil, "editableParameters": card?.taskSurface?.fields ?? [],
                            "browserOpened": !model.webURL.isEmpty, "source": card?.taskSurface?.apiData?.url ?? "",
                        ]))
                    exit(card != nil && editable ? 0 : 1)
                }
                var fetches = 0
                model.apiData = APIDataService(
                    code: model.taskCode,
                    fetch: { url in
                        fetches += 1
                        return try await PublicDataClient().fetch(url)
                    })
                let start = Date()
                let spec = currency()
                let values = try await model.apiData.read(spec)
                let surface = try spec.surface(title: "Currency conversion", state: values)
                let id = UUID()
                model.publishTaskSurface(surface, id: id)
                print(JSONText.encode(["ok": true, "seconds": Date().timeIntervalSince(start), "values": values]))
                if CommandLine.arguments.contains("--preview-api") {
                    delegate.model.selectedTaskID = id
                    model.selectTask(id, expanded: true)
                    func descendants(_ root: NSView) -> [WKWebView] {
                        (root as? WKWebView).map { [$0] } ?? root.subviews.flatMap(descendants)
                    }
                    var card: WKWebView?
                    for _ in 0..<40 {
                        for candidate in descendants(delegate.panel.contentView!) {
                            if (try? await candidate.evaluateJavaScript(
                                "!!document.querySelector('[data-field=amount]')")) as? Bool == true
                            {
                                card = candidate
                                break
                            }
                        }
                        if card != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let card else { throw AppError.message("Editable parameters did not render") }
                    _ = try await card.evaluateJavaScript(
                        "const input=document.querySelector('[data-field=amount]');input.value='100';input.dispatchEvent(new Event('input',{bubbles:true}));"
                    )
                    let expected = String(format: "%.2f", 100 * (Double(values["rate"] ?? "") ?? 0))
                    for _ in 0..<60 {
                        if model.sideTasks.first(where: { $0.id == id })?.liveValues?["converted"] == expected { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard model.sideTasks.first(where: { $0.id == id })?.liveValues?["converted"] == expected,
                        fetches == 1
                    else { throw AppError.message("Rendered input did not recalculate locally") }
                    _ = try await card.evaluateJavaScript(
                        "const select=document.querySelector('[data-field=toCurrency]');select.value='USD';select.dispatchEvent(new Event('change',{bubbles:true}));"
                    )
                    for _ in 0..<100 {
                        if model.sideTasks.first(where: { $0.id == id })?.liveValues?["quote"] == "USD" { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard model.sideTasks.first(where: { $0.id == id })?.liveValues?["quote"] == "USD", fetches == 2
                    else { throw AppError.message("Rendered source selection did not fetch the new unit") }
                    let fits =
                        try await card.evaluateJavaScript(
                            "[...document.querySelectorAll('input,select,button')].every(n=>{const r=n.getBoundingClientRect();return r.right<=innerWidth&&r.bottom<=innerHeight&&r.left>=0})"
                        ) as? Bool
                    guard fits == true else { throw AppError.message("Data controls are clipped") }
                    print(
                        JSONText.encode([
                            "interactiveUI": true, "localEditFetches": 0, "sourceEditFetches": 1, "controlsFit": true,
                        ]))
                    fflush(stdout)
                } else {
                    exit(0)
                }
            } catch {
                print(JSONText.encode(["ok": false, "error": error.localizedDescription]))
                exit(1)
            }
        }
    }
#endif
