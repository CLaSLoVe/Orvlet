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
            let inventory: [String:Any] = ["depots":["north":["count":24],"south":["count":40]],"unit":"pieces","updated":1795046551]
            let inventorySample = APIDataService.Sample(url:"https://example.org/inventory",checked:Date(),response:inventory)
            let intent: [String:Any] = ["source":inventorySample.url,"title":"Inventory","subject":"{depot} stock",
                "parameters":["depot":["label":"Depot","value":"north","choicesFrom":"/depots"],"group":["label":"Group size","value":6]],
                "bindings":["count":"/depots/{depot}/count","unit":"/unit"],
                "results":[["label":"Groups","expression":"Number(data.count) / Number(input.group)","unit":"groups"],
                           ["label":"Available","value":"count","unit":"{unit}"]],"updatedAt":"/updated"]
            try ToolContract.validate("build_data_tool",intent)
            var compiled = try DataToolPlan.compile(intent,sample:inventorySample)
            let nestedSource = APIDataService.Sample(url:"https://example.org/items/group/north",checked:Date(),response:["name":"group/north","count":24])
            var nestedPlan: [String:Any] = ["source":nestedSource.url,"title":"Inventory","url":"https://example.org/items/{item}",
                "parameters":["item":["label":"Item","value":"group/north","options":["group/north","group/south"],"verifyAt":"/name"]],
                "bindings":["count":"/count"],"results":[["label":"Count","value":"count"]]]
            nestedPlan["verify"] = ["count":"24"]
            var nested = try DataToolPlan.compile(nestedPlan,sample:nestedSource)
            try check(try nested.requestURL().absoluteString == nestedSource.url,"The compiled path reproduces the observed hierarchical identifier")
            nested.inputs?[nested.controls!.first!.key] = "group/south"
            try check(try nested.requestURL().absoluteString == "https://example.org/items/group/south","Changing a hierarchical identifier preserves path separators without changing the host")
            let variedSource = APIDataService(code:model.taskCode,fetch:{ _ in ["name":"group/south","count":40] })
            let varied = try await variedSource.read(nested)
            try check(varied["result0"] == "40" && nested.expectations?.count == 1,
                "Switching records verifies their identities without pinning the first measured value")
            var inventoryFetches = 0
            let inventoryService = APIDataService(code:model.taskCode,fetch:{ _ in inventoryFetches += 1; return inventory })
            let firstInventory = try await inventoryService.acquire(compiled,previous:inventorySample)
            try check(firstInventory.state["result0"] == "4" && firstInventory.state["toolSubject"] == "north stock" && inventoryFetches == 0,
                      "The host compiler reuses acquired evidence and assembles calculation state without a second fetch")
            let depotKey = compiled.controls!.first { $0.label == "Depot" }!.key
            let groupKey = compiled.controls!.first { $0.label == "Group size" }!.key
            compiled.inputs?[depotKey] = "south"; compiled.inputs?[groupKey] = "8"
            let nextInventory = try await inventoryService.acquire(compiled,previous:inventorySample)
            let inventorySurface = try compiled.surface(title:"Inventory",state:nextInventory.state)
            try check(nextInventory.state["result0"] == "5" && nextInventory.state["toolSubject"] == "south stock"
                && compiled.controls?.first?.options == ["north","south"] && inventorySurface.fields.count == 2
                && inventorySurface.markup.html.contains("data-change='updateData'"),
                "The same domain-independent plan binds a changed object, numeric input, choice control and visible result")
            try check(APIDataSpec.timestamp("1795046551") == APIDataSpec.timestamp("1795046551000"),
                "Standard publication timestamp encodings are decoded by the host")
            var enveloped = intent
            enveloped["bindings"] = ["count":"/data/depots/{depot}/count","unit":"/data/unit"]
            enveloped["updatedAt"] = "/data/updated"
            enveloped["verify"] = ["unit":"pieces"]
            let envelopedSpec = try DataToolPlan.compile(enveloped,sample:inventorySample)
            let envelopedReading = try await inventoryService.acquire(envelopedSpec,previous:inventorySample)
            let ambiguous = APIDataService.Sample(url:inventorySample.url,checked:Date(),response:["data":["unit":"nested"],"unit":"root"])
            try check(envelopedReading.state["result0"] == "4" && envelopedSpec.updatedAtPointer == "/updated"
                && ambiguous.sourcePointer("/data/unit") == "/data/unit",
                "Observation envelopes resolve at the boundary without overriding an actual source data member")
            let keyed = APIDataService.Sample(url:inventorySample.url,checked:Date(),response:["depots":["east/west~1":["count":30]],"unit":"pieces"])
            var keyedIntent = intent
            keyedIntent["parameters"] = ["depot":["label":"Depot","value":"east/west~1","choicesFrom":"/depots"],"group":["label":"Group size","value":6]]
            keyedIntent.removeValue(forKey:"updatedAt")
            let keyedSpec = try DataToolPlan.compile(keyedIntent,sample:keyed)
            let keyedReading = try await inventoryService.acquire(keyedSpec,previous:keyed)
            try check(keyedReading.state["result0"] == "5", "Parameter keys use JSON pointer escaping rather than URL encoding")
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
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "85.00" && fetches == 1,
                "Editing a local parameter recalculates immediately without a model or API request")
            model.refreshAPIData(owner, fields: ["amount": ""], force: false)
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "—" && model.sideTasks.first?.dataIssue == nil,
                "An incomplete input clears the answer and asks for a value without a task failure")
            model.refreshAPIData(owner, fields: ["amount": "56"], force: false)
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            payload["rate"] = 0.9
            model.refreshAPIData(owner)
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "50.40" && fetches == 2,
                "Refreshing a card fetches and recalculates directly without the model or a browser")
            payload["base"] = "USD"
            payload["rate"] = 7
            model.refreshAPIData(owner, fields: ["fromCurrency": "USD"], force: false)
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "392.00" && fetches == 3
                    && model.sideTasks.first?.liveValues?["sourceRequest"]?.hasSuffix("USD/CNY") == true,
                "Changing a source parameter requests the new API URL and verifies its actual returned identity")
            model.refreshAPIData(owner, fields: ["fromCurrency": "HKD"], force: false)
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            model.refreshAPIData(owner)
            await (model.work.view(owner).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[owner])?.value
            try check(
                model.sideTasks.first?.liveValues?["converted"] == "—" && model.sideTasks.first?.dataIssue != nil
                    && model.work.view(owner).flatMap { model.work.artifact($0.selected) }?.values["converted"] == "392.00",
                "A changed source identity cannot label the previous verified reading as the new result"
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
            await (model.work.view(weatherID).flatMap { model.workJobs[$0.selected] } ?? model.taskActionJobs[weatherID])?.value
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
                if rounds == 1 {
                    return ["tool_calls": [RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "advanced_data"])).call]]
                }
                if rounds == 3 {
                    let feedback = turns.last(where: { $0["role"] as? String == "tool" })?["content"] as? String ?? ""
                    receivedBindingHint =
                        feedback.contains("$.source.fields")
                        && feedback.replacingOccurrences(of: "\\/", with: "/").contains("/quote")
                }
                var echoed = spec
                if rounds == 2 {
                    echoed.fields[1].pointer = "/base"
                    echoed.expectations?.removeValue(forKey: "quote")
                }
                echoed.fields.append(APIDataField(key: "baseEcho", label: "Base echo", pointer: "/base"))
                let input: [String: Any] = [
                    "title": "Currency conversion",
                    "source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(echoed)),
                    "requirements": [["label": "base currency", "anyOf": ["HKD"]], ["label": "quote currency", "anyOf": ["CNY"]]],
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
                rounds == 3 && receivedBindingHint && reply.contains("47.60") && model.browser === browser
                    && model.webURL.isEmpty,
                "API execution repairs a source binding using same-response hints, accepts duplicate echoes and never opens a webpage"
            )
            let mapped: [String:Any] = ["warehouses":["north":["count":12]], "rows":[["count":2]]]
            try check(APIDataSpec.reportedKeys("/warehouses/north/count", in:mapped).contains("north")
                && APIDataSpec.reportedKeys("/warehouses/south/count", in:mapped).isEmpty
                && APIDataSpec.reportedKeys("/warehouses/north/missing", in:mapped).isEmpty
                && !APIDataSpec.reportedKeys("/rows/0/count", in:mapped).contains("0"),
                "Source identity can come from a real record key; missing records, invented paths and array positions cannot prove identity")
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
            var webRounds = 0
            web.agent.completionOverride = { _ in
                webRounds += 1
                @MainActor func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
                    [
                        "id": UUID().uuidString, "type": "function",
                        "function": ["name": name, "arguments": JSONText.encode(args)],
                    ]
                }
                if webRounds == 1 { return ["tool_calls": [call("load_tools", ["family": "web"])]] }
                if webRounds == 2 { return ["tool_calls": [call("observe", [:])]] }
                if webRounds == 3 { return ["tool_calls": [call("compose_ui", ["markup": ["html": "<script>invalid()</script>", "compactHTML": "", "css": ""], "readings": [], "actions": []])]] }
                return ["role": "assistant", "tool_calls": [call(
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
                            ])]]
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
            checks += try await backgroundReading()
            return checks
        }
        static func backgroundReading() async throws -> [String] {
            let suite = "orvlet.background." + UUID().uuidString
            let store = UserDefaults(suiteName: suite)!
            let model = AppModel(defaults: store)
            defer { store.removePersistentDomain(forName: suite) }
            model.isLiveTest = true
            model.persistHistory = false
            defer {
                model.dataRefreshTimer?.invalidate()
                model.adaptive.invalidate()
                model.browser.dispose()
            }
            let today = "2026-01-01"
            var checks: [String] = []
            func check(_ ok: Bool, _ message: String) throws {
                guard ok else { throw AppError.message(message) }
                checks.append(message)
            }
            // A retained reading must update while the user is away, including after restoring its recipe.
            var reading = APIDataSpec(url: "https://example.org/reading", fields: [
                APIDataField(key: "rate", label: "Reading", pointer: "/rate"),
                APIDataField(key: "date", label: "Published", pointer: "/date")
            ])
            reading.refreshSeconds = 60
            reading.card = DataCardPreset(kind: .reading, primaryKey: "rate", subject: "Gauge")
            var projection = reading
            projection.outputs = [.init(key: "rate", label: "Current")]
            let sample = ["rate": "16", "date": today]
            let direct = try await model.apiData.calculate(projection, state: sample)
            try check(direct["rate"] == "16", "A fetched reading can be listed as an output without generated code")
            projection.outputs?.append(.init(key: "doubleRate", label: "Double"))
            projection.calculation = "return {state:{...state, doubleRate:Number(state.rate)*2, scratch:5}};"
            let calculated = try await model.apiData.calculate(projection, state: sample)
            try check(calculated["doubleRate"] == "32" && calculated["rate"] == "16" && calculated["scratch"] == nil,
                "Project the declared derived result and preserve the verified source field")
            projection.calculation = "return {state:{wrong:32}};"
            do {
                _ = try await model.apiData.calculate(projection, state: sample)
                throw AppError.message("Published a missing calculation result")
            } catch let error as ToolArgumentError {
                try check(error.path == "$.source.calculation" && error.issue.contains("doubleRate") && error.issue.contains("wrong"),
                    "Repair identifies the missing output and the actual returned key")
            }
            projection.calculation = "return {rate:0, doubleRate:32};"
            do {
                _ = try await model.apiData.calculate(projection, state: sample)
                throw AppError.message("Published a modified source reading")
            } catch let error as ToolArgumentError {
                try check(error.issue.contains("changes fetched field"), "Calculations cannot replace a verified source output")
            }
            let saved = try JSONDecoder().decode(APIDataSpec.self, from: JSONEncoder().encode(reading))
            var reads = 0
            model.apiData = APIDataService(code: model.taskCode, fetch: { _ in
                reads += 1
                return ["rate": reads, "date": today] as [String: Any]
            })
            let first = try await model.apiData.read(saved)
            let readingSurface = try saved.surface(title: "Gauge readings", state: first)
            let readingID = UUID()
            model.publishTaskSurface(readingSurface, id: readingID)
            let readingIndex = model.sideTasks.firstIndex { $0.id == readingID }!
            if let id = model.work.view(readingID)?.selected, let artifact = model.work.artifact(id) {
                model.work.update(id,expecting:artifact.revision) { $0.checked = Date().addingTimeInterval(-61) }
                model.projectWorkResult(id)
            }
            model.collapsed = true
            model.selectedTaskID = nil
            model.scheduleDataRefresh()
            for _ in 0..<40 {
                if model.sideTasks[readingIndex].state["rate"] == "2" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(model.sideTasks[readingIndex].state["rate"] == "2" && reads == 2
                && readingSurface.markup.compactHTML.contains("Gauge")
                && CardMarkup.bindingKeys(in: readingSurface.markup.compactHTML).contains("rate")
                && CardMarkup.bindingKeys(in: readingSurface.markup.html).contains("rate"),
                "An unselected collapsed reading refreshes its shared primary value once")
            model.beginAmbientRequest("Check the current reading", taskID: readingID)
            model.busy = true
            model.agent.nativeRequestActive = true
            model.agent.activeTaskID = readingID
            let result = try await model.agent.execute("control_task", ["operation": "invoke", "action": "refreshData"])
            try check(result["verified"] as? Bool == true && reads == 3 && model.sideTasks[readingIndex].state["rate"] == "3",
                "Chat invokes the registered remote action and verifies its new value")
            _ = try await model.agent.execute("control_task", ["operation": "refresh"])
            try check(reads == 4 && model.sideTasks[readingIndex].state["rate"] == "4", "Direct refresh uses the same source")
            _ = try await model.agent.execute("control_task", ["operation": "refresh"])
            try check(reads == 4, "A duplicate action reuses its verified receipt")
            model.apiData = APIDataService(code: model.taskCode, fetch: { _ in throw URLError(.notConnectedToInternet) })
            do {
                _ = try await model.agent.execute("control_task", ["operation": "invoke", "action": "refreshData", "fields": [:]], requestScoped: false)
                throw AppError.message("Offline read reported success")
            } catch {
                try check(model.sideTasks[readingIndex].status == "Update unavailable" && model.sideTasks[readingIndex].state["rate"] == "4" && model.sideTasks[readingIndex].dataIssue != nil, "An unavailable source preserves the last verified value")
            }
            model.agent.nativeRequestActive = false
            model.busy = false
            model.finishAmbientRequest()
            var legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try check(legacy.preferredInterfaceLanguage == "English", "Legacy settings default to English")
            var draft = legacy
            draft.interfaceLanguage = "  Português do Brasil  "
            legacy.applyPreferences(from: draft)
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(legacy))
            try check(restored.preferredInterfaceLanguage == "Português do Brasil" && restored.interfaceLanguageInstruction.contains("Português do Brasil"), "A freely entered interface language survives a settings round trip")
            draft.interfaceLanguage = "  "
            legacy.applyPreferences(from: draft)
            try check(legacy.preferredInterfaceLanguage == "English", "Clearing the preference restores English")
            var attempts = 0
            let recovered = try await PublicDataClient.readWithRetry {
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return 9
            }
            try check(attempts == 2 && recovered == 9, "A dropped public read recovers with one retry")
            attempts = 0
            do {
                _ = try await PublicDataClient.readWithRetry { () -> Int in
                    attempts += 1
                    throw URLError(.notConnectedToInternet)
                }
            } catch let failure as URLError where failure.code == .notConnectedToInternet {}
            try check(attempts == 1, "A known offline state does not spin on retries")

            var editable = reading
            editable.inputs = ["station": "North"]
            editable.expectations = ["stationID": "{station}"]
            editable.fields.append(.init(key: "stationID", label: "Station", pointer: "/station"))
            editable.fields.append(.init(key: "place", label: "Location", pointer: "/place"))
            editable.card?.displayNameKey = "place"
            editable.card?.primaryKey = " RATE "
            editable.card?.detailKeys = ["missing", "DATE", "date"]
            var station = "North"
            var stationReads = 0
            model.apiData = APIDataService(code: model.taskCode, fetch: { _ in
                stationReads += 1
                return ["rate": station == "North" ? "12" : "17", "station": station, "place": station + " Pier", "date": today]
            })
            editable = try editable.validated()
            try check(editable.card?.primaryKey == "rate" && editable.card?.detailKeys == ["date"], "Unambiguous card slots are repaired without changing the primary meaning")
            let snapshot = try await model.apiData.read(editable)
            let stationID = UUID()
            model.publishTaskSurface(try editable.surface(title: "Station", state: snapshot), id: stationID)
            let initialStation = model.sideTasks.first { $0.id == stationID }
            try check(initialStation?.state["place"] == "North Pier"
                && initialStation.map { CardMarkup.bindingKeys(in: $0.presentation.compactHTML).contains("place") } == true,
                "A station capsule binds the fetched display name independently of its lookup key")
            await model.refreshAPIData(stationID, fields: ["station": "South"], force: false)?.value
            let wrong = model.sideTasks.first { $0.id == stationID }
            try check(stationReads == 2 && wrong?.state["rate"] == "—" && model.work.view(stationID).flatMap { model.work.artifact($0.selected) }?.values["rate"] == "12",
                "An identity edit on the same URL refetches and keeps the previous station out of the new view")
            station = "South"
            await model.refreshAPIData(stationID)?.value
            let newStation = model.sideTasks.first { $0.id == stationID }
            try check(newStation?.state["rate"] == "17" && newStation?.state["place"] == "South Pier"
                && newStation?.presentation.compactHTML == initialStation?.presentation.compactHTML,
                "The same capsule follows the changed station name and reading without regenerating its layout")
            model.closeTask(stationID)

            var archive = SavedTaskList()
            let active = SideTask(kind: .workspace, title: "Notes")
            let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(active))
            let unknownID = UUID()
            let bad = ["id": unknownID.uuidString, "kind": "future"]
            let mixed = try JSONSerialization.data(withJSONObject: [record, bad, record])
            let good = archive.read(mixed)
            let preserved = try JSONSerialization.jsonObject(with: archive.encoded(good)) as! [[String: Any]]
            try check(good.map(\.id) == [active.id] && preserved.count == 2 && preserved[1]["kind"] as? String == "future", "A malformed saved task and duplicate ID leave other tasks restorable without losing the unknown record")
            archive.remove(unknownID)
            try check(try JSONDecoder().decode([SideTask].self, from: archive.encoded(good)).count == 1, "Explicit deletion removes retained unreadable records")
            let empty = APIDataSpec(url: reading.url, fields: [])
            do {
                _ = try empty.surface(title: "Saved reading", state: [:])
                throw AppError.message("Empty saved recipe unexpectedly rendered")
            } catch let error as ToolArgumentError { try check(error.path == "$.source.fields", "An empty saved data recipe cannot crash restoration") }
            try await CardVisualCheck.run()
            checks.append("A non-financial card renders and refreshes a real WebKit chart and table")
            model.closeTask(readingID)
            try check(model.dataRefreshTimer != nil, "Closing a reading view does not silently stop its retained schedule")
            for artifact in model.work.snapshot.artifacts.values where artifact.definition.apiData?.refreshSeconds != nil {
                await model.performWorkOperation(artifact.id,action:"stopUpdates",fields:[:])?.value
            }
            try check(model.dataRefreshTimer == nil, "Explicitly stopping retained schedules releases the timer without requiring cards")
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
