#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum BuiltinCardsCheck {
        static func start(_ model: AppModel, delegate: AppDelegate) async {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            func descendants(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
            }
            func rendered(_ selector: String, ready: String = "true") async throws -> WKWebView {
                for _ in 0..<60 {
                    for web in descendants(delegate.panel.contentView!) {
                        if (try? await web.evaluateJavaScript(
                            "!!document.querySelector('" + selector + "') && (" + ready + ")")) as? Bool
                            == true
                        {
                            try await Task.sleep(for: .milliseconds(250))
                            return web
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw AppError.message("Preset did not render: " + selector)
            }
            func inspect(_ web: WKWebView, name: String) async throws {
                try await Task.sleep(for: .milliseconds(350))
                try check(
                    (try await web.evaluateJavaScript("lastHeight>0")) as? Bool == true,
                    name + " measures content without waiting for an animation frame")
                let metrics =
                    try await web.evaluateJavaScript(
                        "JSON.stringify({height:innerHeight,measure:window.measureContent,reported:lastHeight,surface:document.querySelector('#surface').clientHeight,scroll:document.querySelector('#surface').scrollHeight,controls:[...document.querySelectorAll('#surface button,#surface input,#surface select')].map(n=>({tag:n.tagName,text:n.textContent.substring(0,30),top:n.getBoundingClientRect().top,bottom:n.getBoundingClientRect().bottom,height:n.getBoundingClientRect().height}))})"
                    ) as? String
                try metrics?.write(
                    toFile: "/tmp/orvlet-preset-" + name + "-layout.json", atomically: true, encoding: .utf8)
                let fits =
                    try await web.evaluateJavaScript(
                        "(()=>{const s=document.querySelector('#surface'),b=s.getBoundingClientRect();return s.scrollHeight<=s.clientHeight+1 && [...document.querySelectorAll('#surface button,#surface input,#surface select,.preset-number,.clock-time')].every(n=>{const r=n.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth+1&&r.bottom<=b.bottom+1})})()"
                    ) as? Bool
                if fits != true {
                    print(
                        "LAYOUT", name,
                        model.sideTasks.first(where: { $0.id == model.selectedTaskID })?.presentation.height ?? -1,
                        delegate.panel.frame)
                }
                try check(fits == true, name + " keeps its essential values and controls inside the rendered card")
                try check(
                    (try await web.evaluateJavaScript(
                        "[...document.querySelectorAll('#surface button,#surface input,#surface select')].every(n=>n.getBoundingClientRect().height>=31.5)"
                    )) as? Bool == true, name + " keeps controls at least 32 pixels tall")
                let image = try await web.takeSnapshot(configuration: nil)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                    let data = bitmap.representation(using: .png, properties: [:])
                else { throw AppError.message("Missing preset screenshot") }
                try data.write(to: URL(fileURLWithPath: "/tmp/orvlet-preset-" + name + ".png"))
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-preset-panel-" + name + ".png")
            }
            do {
                model.isLiveTest = true
                model.persistHistory = false
                model.settings = AppSettings()
                model.settings.autoAdapt = false
                model.settings.reduceMotion = true
                model.settings.appearance = .light
                model.sideTasks.removeAll()
                model.taskRuntime.stopAll()
                model.dismissFeedback()
                model.selectChat(false)
                model.setCompactLayout(.vertical)
                let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
                var fetches = 0
                var rate = 0.85
                model.apiData = APIDataService(
                    code: model.taskCode,
                    fetch: { url in
                        fetches += 1
                        let pair = URL(string: url)!.path.split(separator: "/").suffix(2)
                        let reversed = ["EUR", "CNY"].contains(String(pair.first!))
                        return [
                            "date": today, "base": String(pair.first!), "quote": String(pair.last!),
                            "rate": reversed ? 1 / rate : rate,
                        ]
                    })
                var currency = APIDataCheck.currency()
                currency.card = DataCardPreset(kind: .currency, primaryKey: "converted", unitKey: "quote")
                currency = try currency.validated()
                let surface = try currency.surface(title: "Currency", state: try await model.apiData.read(currency))
                try check(
                    surface.fields == ["amount", "fromCurrency", "toCurrency"],
                    "Currency preserves Amount, From, To control order")
                let id = UUID()
                model.publishTaskSurface(surface, id: id)
                model.activeRequest = nil
                model.selectTask(id, expanded: true)
                let card = try await rendered(".currency-preset")
                try check(
                    (try await card.evaluateJavaScript(
                        "[...document.querySelectorAll('input,select,button')].every(n=>n.getBoundingClientRect().height>=32)"
                    )) as? Bool == true,
                    "Currency input, currency selectors and refresh retain comfortable 32-pixel targets")
                _ = try await card.evaluateJavaScript(
                    "const amount=document.querySelector('[data-field=amount]');amount.value='100';amount.dispatchEvent(new Event('input',{bubbles:true}));true"
                )
                for _ in 0..<60 {
                    if model.sideTasks.first(where: { $0.id == id })?.state["converted"] == "85.00" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    model.sideTasks.first(where: { $0.id == id })?.state["converted"] == "85.00" && fetches == 1,
                    "Typing an amount in the built-in card recalculates without a model or second fetch")
                rate = 0.9
                _ = try await card.evaluateJavaScript("document.querySelector('[data-action=refreshData]').click()")
                for _ in 0..<60 {
                    if model.sideTasks.first(where: { $0.id == id })?.state["converted"] == "90.00" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    model.sideTasks.first(where: { $0.id == id })?.state["converted"] == "90.00" && fetches == 2,
                    "Rendered Refresh fetches a new rate and replaces the result")
                try await inspect(card, name: "currency-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(card, name: "currency-dark")
                model.settings.appearance = .light

                // Exercise the actual agent executor, not a copy of its saved-recipe logic.
                model.interfaceMemory.remember(
                    model.sideTasks.first(where: { $0.id == id })!, purpose: "Currency conversion")
                model.settings.useFast = true
                let reuseText = "Convert 200 USD to EUR using the saved card"
                let candidates = FastCardReuse.candidates(text: reuseText, recipes: model.interfaceMemory.recipes)
                let advice = try FastCardReuseCheck.decode(
                    FastCardReuseCheck.answers(
                        text: reuseText, cards: candidates, tasks: [model.sideTasks.first { $0.id == id }!],
                        values: ["amount": "200", "fromCurrency": "USD", "toCurrency": "EUR"]), cards: candidates,
                    tasks: [model.sideTasks.first { $0.id == id }!], explicit: id)
                var decisions = 0
                model.agent.interpretationOverride = { _ in
                    decisions += 1
                    throw AppError.message("Jev reuse unexpectedly invoked the main interpreter")
                }
                model.agent.completionOverride = { _ in
                    decisions += 1
                    throw AppError.message("Jev reuse unexpectedly invoked the main planner")
                }
                _ = try await model.agent.run(
                    reuseText, taskID: id,
                    prepared: PreparedRequest(text: reuseText, triage: advice, model: model))
                let reused = model.sideTasks.first(where: {
                    $0.state["converted"] == "180.00" && $0.state["quote"] == "EUR"
                })
                try check(
                    decisions == 0 && fetches == 3 && reused != nil,
                    "Jev-matched currency executes with zero main-model calls and fresh data for the new pair")
                model.activeRequest = nil
                model.selectTask(reused!.id, expanded: true)
                let reusedCard = try await rendered(
                    ".currency-preset",
                    ready:
                        "document.querySelector('[data-field=amount]').value==='200' && document.querySelector('[data-field=fromCurrency]').value==='USD'"
                )
                try check(
                    (try await reusedCard.evaluateJavaScript(
                        "document.querySelector('[data-bind=converted]').textContent.includes('180.00') && document.querySelector('[data-field=fromCurrency]').value==='USD' && document.querySelector('[data-field=toCurrency]').value==='EUR'"
                    )) as? Bool == true,
                    "The actually rendered Jev-reused card shows the new result and both new currencies")
                try await inspect(reusedCard, name: "jev-reused-currency")
                _ = try await reusedCard.evaluateJavaScript(
                    "document.querySelector('[data-action=swapCurrencies]').click()")
                for _ in 0..<60 {
                    if model.sideTasks.first(where: { $0.id == reused!.id })?.state["converted"] == "222.22" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    fetches == 4 && model.sideTasks.first(where: { $0.id == reused!.id })?.state["quote"] == "USD",
                    "Swap exchanges both currencies atomically and fetches one verified reciprocal result")
                try check(
                    (try await reusedCard.evaluateJavaScript(
                        "document.querySelector('[data-field=fromCurrency]').value==='EUR' && document.querySelector('[data-field=toCurrency]').value==='USD' && document.querySelector('[data-bind=currencyFromName]').textContent.includes('Euro')"
                    )) as? Bool == true,
                    "Swapping updates the visible selectors and readable currency names")
                _ = try await reusedCard.evaluateJavaScript(
                    "const a=document.querySelector('[data-field=amount]');a.value='180';a.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));true"
                )
                for _ in 0..<60 {
                    if model.sideTasks.first(where: { $0.id == reused!.id })?.state["converted"] == "200.00" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    fetches == 4
                        && model.sideTasks.first(where: { $0.id == reused!.id })?.state["converted"] == "200.00",
                    "Enter in the amount field recalculates locally and never triggers the Swap button")
                model.agent.completionOverride = nil
                model.agent.interpretationOverride = nil
                model.activeRequest = nil

                // Recreate a previous host-generated form, including its plain currency inputs.
                var legacy = surface
                legacy.preset = nil
                legacy.apiData?.card = nil
                legacy.apiData?.controls = [
                    APIDataControl(key: "amount", label: "Amount", kind: "number"),
                    APIDataControl(key: "fromCurrency", label: "From"),
                    APIDataControl(key: "toCurrency", label: "To"),
                ]
                legacy.markup = CardMarkup(
                    html:
                        "<section class='data-result'><div class='data-inputs'><input type='number' data-field='amount'><input data-field='fromCurrency'><input data-field='toCurrency'></div><strong data-bind='converted'></strong><span data-bind='quote'></span><button data-action='refreshData'>Refresh</button></section>",
                    compactHTML: "<strong data-bind='converted'></strong><span data-bind='quote'></span>",
                    css: APIDataSpec.genericDataCSS)
                let legacyID = UUID()
                model.publishTaskSurface(try legacy.validated(), id: legacyID)
                model.sideTasks[model.sideTasks.firstIndex(where: { $0.id == legacyID })!].dataUpdatedAt = Date()
                model.selectTask(legacyID, expanded: true)
                let migratedCard = try await rendered(
                    ".currency-preset", ready: "document.querySelector('[data-field=fromCurrency]').options.length>64")
                let upgraded = model.sideTasks.first(where: { $0.id == legacyID })!
                try check(
                    upgraded.taskSurface?.preset == "currency"
                        && upgraded.presentation.html.contains("swapCurrencies")
                        && upgraded.title == "Currency converter",
                    "Opening an old standard currency form upgrades its picker and layout without another model call")
                try check(
                    (try await migratedCard.evaluateJavaScript("document.querySelectorAll('select').length===2"))
                        as? Bool == true,
                    "Legacy plain-text currency fields become actual keyboard-accessible native selectors")
                let choices = FastCardReuse.candidates(
                    text: "Convert 100 USD to CNY", recipes: [try model.interfaceMemory.recipe(legacyID.uuidString)])
                try check(
                    choices.count == 1 && choices[0].slots.allSatisfy({ $0.values.count <= 64 }),
                    "A complete native currency picker retains a bounded Jev reuse path")
                var custom = upgraded.presentation
                custom.css += ".preset-number{font-size:28px}"
                try model.applyInterfaceRevision(legacyID, markup: custom, original: upgraded)
                model.upgradeStandardCard(legacyID)
                let customized = model.sideTasks.first(where: { $0.id == legacyID })!
                let recreated = try customized.taskSurface!.apiData!.surface(
                    title: customized.title, state: customized.state, proposed: customized.presentation)
                try check(
                    recreated.markup.hasSameDesign(as: custom) && recreated.apiData?.customLayout == true,
                    "A deliberate user layout edit survives both template migration and saved-method reconstruction")

                var weatherFetches = 0
                model.apiData = APIDataService(
                    code: model.taskCode,
                    fetch: { raw in
                        weatherFetches += 1
                        let city = URL(string: raw)!.path.contains("London") ? "London" : "Hong Kong"
                        return [
                            "nearest_area": [
                                [
                                    "areaName": [["value": city]],
                                    "country": [["value": city == "London" ? "United Kingdom" : "Hong Kong"]],
                                ]
                            ],
                            "weather": (0...2).map { day in
                                [
                                    "date": "2026-11-0\(4 + day)", "maxtempC": String(26 + day), "mintempC": "25",
                                    "hourly": [
                                        [
                                            "time": "1200", "weatherDesc": [["value": "Sunny"]], "chanceofrain": "7",
                                            "precipMM": "0.0",
                                        ]
                                    ],
                                ] as [String: Any]
                            },
                        ] as [String: Any]
                    })
                let weather = try APIDataSpec(
                    url: "https://wttr.in/Hong_Kong?format=j1",
                    fields: [
                        APIDataField(key: "temperature", label: "Temperature", pointer: "/weather/1/maxtempC"),
                        APIDataField(key: "low", label: "Low", pointer: "/weather/1/mintempC"),
                        APIDataField(key: "date", label: "Date", pointer: "/weather/1/date"),
                        APIDataField(key: "country", label: "Location", pointer: "/nearest_area/0/country/0/value"),
                        APIDataField(
                            key: "condition", label: "Condition", pointer: "/weather/1/hourly/0/weatherDesc/0/value"),
                        APIDataField(key: "rain", label: "Rain chance", pointer: "/weather/1/hourly/0/chanceofrain"),
                        APIDataField(key: "precip", label: "Precipitation", pointer: "/weather/1/hourly/0/precipMM"),
                    ],
                    expectations: ["country": "Hong Kong", "date": "2026-11-05"],
                    card: DataCardPreset(kind: .weather, primaryKey: "temperature", contextKey: "country")
                ).validated()
                let weatherState = try await model.apiData.read(weather)
                try check(
                    weather.fields.first?.unit == "°C" && weather.inputs?["weatherDay"] == "1"
                        && weather.inputs?["weatherLocation"] == "Hong Kong",
                    "Legacy wttr forecast gains source-defined units and real location/day parameters")
                let weatherID = UUID()
                model.publishTaskSurface(try weather.surface(title: "Weather", state: weatherState), id: weatherID)
                if let index = model.sideTasks.firstIndex(where: { $0.id == weatherID }) {
                    model.sideTasks[index].dataUpdatedAt = Date()
                }
                model.activeRequest = nil
                model.selectTask(weatherID, expanded: true)
                let weatherCard = try await rendered(".weather-preset")
                try check(
                    (try await weatherCard.evaluateJavaScript(
                        "document.querySelector('.preset-number').textContent.includes('27') && document.querySelector('.preset-number').textContent.includes('°C') && document.querySelector('.preset-result').textContent.includes('High') && document.querySelector('.preset-details').textContent.includes('%') && document.querySelector('.preset-details').textContent.includes('mm')"
                    )) as? Bool == true,
                    "Weather labels the daily high and shows temperature, probability and precipitation units")
                try check(
                    (try await weatherCard.evaluateJavaScript(
                        "!document.body.textContent.includes('Source update time unavailable') && document.body.textContent.includes('At 12:00')"
                    )) as? Bool == true,
                    "Weather separates the sampled condition time and omits missing-timestamp boilerplate")
                try await inspect(weatherCard, name: "weather-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(weatherCard, name: "weather-dark")
                model.settings.appearance = .light
                _ = try await weatherCard.evaluateJavaScript(
                    "const day=document.querySelector('[data-field=weatherDay]');day.value='0';day.dispatchEvent(new Event('change',{bubbles:true}));true"
                )
                for _ in 0..<50 {
                    if model.sideTasks.first(where: { $0.id == weatherID })?.state["temperature"] == "26" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    weatherFetches == 2
                        && model.sideTasks.first(where: { $0.id == weatherID })?.state["date"] == "2026-11-04",
                    "Forecast selector fetches and extracts the new day instead of reusing the old readings")
                _ = try await weatherCard.evaluateJavaScript(
                    "const city=document.querySelector('[data-field=weatherLocation]');city.value='London';city.dispatchEvent(new Event('change',{bubbles:true}));true"
                )
                for _ in 0..<50 {
                    if model.sideTasks.first(where: { $0.id == weatherID })?.state["weatherCity"] == "London" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    weatherFetches == 3
                        && model.sideTasks.first(where: { $0.id == weatherID })?.state["weatherCity"] == "London",
                    "City field executes the changed source URL and displays the returned location")
                _ = try await weatherCard.evaluateJavaScript(
                    "document.querySelector('[data-action=refreshData]').click()")
                for _ in 0..<30 {
                    if weatherFetches == 4 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(weatherFetches == 4, "Weather refresh performs a fresh acquisition")
                var invalid = weather
                invalid.card?.primaryKey = "invented"
                var rejected = false
                do { _ = try invalid.validated() } catch { rejected = true }
                try check(rejected, "A preset cannot bind a fabricated primary result")

                let timerID = try model.startTimer(seconds: 720, title: "Tea break")
                model.activeRequest = nil
                model.selectTask(timerID, expanded: true)
                let timerCard = try await rendered(".timer-preset")
                _ = try await timerCard.evaluateJavaScript("document.querySelector('[data-action=toggle]').click()")
                for _ in 0..<30 {
                    if model.sideTasks.first(where: { $0.id == timerID })?.deadline == nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    model.sideTasks.first(where: { $0.id == timerID })?.status == "Paused",
                    "The designed timer pauses the real native deadline")
                let paused = model.sideTasks.first(where: { $0.id == timerID })!.remaining
                _ = try await timerCard.evaluateJavaScript("document.querySelector('[data-action=addMinute]').click()")
                try await Task.sleep(for: .milliseconds(250))
                try check(
                    abs(model.sideTasks.first(where: { $0.id == timerID })!.remaining - paused - 60) < 1
                        && model.sideTasks.first(where: { $0.id == timerID })?.deadline == nil,
                    "Add one minute changes the actual paused timer without resuming it")
                _ = try await timerCard.evaluateJavaScript("document.querySelector('[data-action=restart]').click()")
                for _ in 0..<30 {
                    if let timer = model.sideTasks.first(where: { $0.id == timerID }), timer.deadline != nil,
                        timer.remaining > 719
                    {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    (model.sideTasks.first(where: { $0.id == timerID })?.remaining ?? 0) > 718,
                    "Restart resets the actual timer to its original duration")
                _ = try await rendered(
                    ".timer-preset", ready: "document.querySelector('[data-action=toggle]').textContent==='Pause'")
                try await inspect(timerCard, name: "timer-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(timerCard, name: "timer-dark")
                model.settings.appearance = .light

                let event: [String: Any] = [
                    "verified": true, "title": "Design review", "start": today + "T14:00:00",
                    "end": today + "T15:00:00", "sourceTimeZone": TimeZone.current.identifier, "location": "Studio 2",
                ]
                let calendarID = model.addCalendarCard(event)!
                let allDay = CalendarService.cardState([
                    "start": "2026-11-04T00:00:00", "end": "2026-11-05T00:00:00",
                    "sourceTimeZone": "America/New_York", "allDay": true,
                ])
                try check(
                    allDay?["eventDate"] == "Wed, Nov 4, 2026" && allDay?["eventTime"] == "All day"
                        && allDay?["eventZone"] == "",
                    "All-day cards preserve the calendar date without shifting it into another time zone")
                let multiDay = CalendarService.cardState([
                    "start": "2026-11-04T00:00:00", "end": "2026-11-06T00:00:00", "allDay": true,
                ])
                try check(
                    multiDay?["eventTime"] == "All day · through Nov 5",
                    "Multi-day calendar cards display the inclusive last day, not the exclusive end boundary")
                if let i = model.sideTasks.firstIndex(where: { $0.id == calendarID }) {
                    model.sideTasks[i].expires = nil
                }
                model.selectTask(calendarID, expanded: true)
                let calendarCard = try await rendered(".calendar-preset")
                try check(
                    (try await calendarCard.evaluateJavaScript(
                        "document.querySelector('[data-bind=eventTime]').textContent==='14:00–15:00' && document.querySelector('[data-bind=eventLocation]').textContent==='Studio 2'"
                    )) as? Bool == true,
                    "Calendar presents the actual event time and location as separate readable values")
                let previousApp = NSWorkspace.shared.frontmostApplication
                var calendarOpened = false
                model.calendarOpenCheck = { calendarOpened = $0 }
                _ = try await calendarCard.evaluateJavaScript(
                    "document.querySelector('[data-action=calendar]').click()")
                for _ in 0..<50 {
                    if calendarOpened { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(
                    calendarOpened,
                    "Open Calendar button opens the real Calendar application without creating another event")
                model.calendarOpenCheck = nil
                _ = previousApp?.activate(options: [])
                try await inspect(calendarCard, name: "calendar-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(calendarCard, name: "calendar-dark")
                model.settings.appearance = .light

                let clockRuntime = TaskRuntimeSpec(sources: [
                    TaskDataSource(key: "localTime", kind: .clock, format: .time, timeZone: "Asia/Hong_Kong"),
                    TaskDataSource(key: "localDate", kind: .clock, format: .date, timeZone: "Asia/Hong_Kong"),
                ])
                let clockID = UUID()
                let clock = try TaskSurface(
                    title: "Time", markup: BuiltinCards.clock(clockRuntime), fields: [], actions: [], state: [:],
                    runtime: clockRuntime, preset: "clock"
                ).validated()
                model.publishTaskSurface(clock, id: clockID)
                model.activeRequest = nil
                model.selectTask(clockID, expanded: true)
                let clockCard = try await rendered(".clock-preset")
                let first =
                    try await clockCard.evaluateJavaScript("document.querySelector('.clock-time').textContent")
                    as? String
                try await Task.sleep(for: .milliseconds(1200))
                let second =
                    try await clockCard.evaluateJavaScript("document.querySelector('.clock-time').textContent")
                    as? String
                try check(
                    first != second && second?.isEmpty == false,
                    "The rendered preset clock advances from the local runtime")
                try await inspect(clockCard, name: "clock-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(clockCard, name: "clock-dark")
                _ = try await clockCard.evaluateJavaScript(
                    "const zone=document.querySelector('[data-field=clockZone0]');zone.value='Europe/Paris';zone.dispatchEvent(new Event('change',{bubbles:true}));true"
                )
                try await Task.sleep(for: .milliseconds(350))
                try check(
                    model.sideTasks.first(where: { $0.id == clockID })?.taskSurface?.runtime?.sources.allSatisfy({
                        $0.timeZone == "Europe/Paris"
                    }) == true, "Clock picker updates both live time and date sources to the chosen zone")
                let changedClock = try await rendered(
                    ".clock-preset", ready: "document.querySelector('[data-field=clockZone0]').value==='Europe/Paris'")
                _ = try await changedClock.evaluateJavaScript(
                    "const format=document.querySelector('[data-field=clockHourStyle]');format.value='12h';format.dispatchEvent(new Event('change',{bubbles:true}));true"
                )
                try await Task.sleep(for: .milliseconds(350))
                try check(
                    model.sideTasks.first(where: { $0.id == clockID })?.taskSurface?.runtime?.sources.first?.hour12
                        == true, "Time-format control changes the runtime rather than a static label")
                model.settings.appearance = .light

                model.interfaceMemory.remember(
                    model.sideTasks.first(where: { $0.id == clockID })!, purpose: "Local time")
                var london = clockRuntime
                for index in london.sources.indices { london.sources[index].timeZone = "Europe/London" }
                let londonSpec = try JSONSerialization.jsonObject(with: JSONEncoder().encode(london))
                model.agent.interpretationOverride = { _ in
                    RequestIntent(kind: .general, behavior: .advancing, timeZones: ["Europe/London"], route: .local)
                }
                decisions = 0
                model.agent.completionOverride = { _ in
                    decisions += 1
                    return [
                        "role": "assistant",
                        "tool_calls": [
                            [
                                "id": UUID().uuidString, "type": "function",
                                "function": [
                                    "name": "reuse_saved_ui",
                                    "arguments": JSONText.encode([
                                        "id": clockID.uuidString, "runtime": londonSpec, "state": [String: String](),
                                    ]),
                                ],
                            ]
                        ],
                    ]
                }
                _ = try await model.agent.run("Show the current time in London using the saved clock")
                guard
                    let reusedClock = model.sideTasks.first(where: {
                        $0.taskSurface?.runtime?.sources.first?.timeZone == "Europe/London"
                    })
                else { throw AppError.message("Saved clock kept the old zone") }
                try check(
                    decisions == 1 && reusedClock.state["clockLocationLabel"] == "London"
                        && reusedClock.state["clockZone0"] == "Europe/London",
                    "Saved clock verifies the newly requested zone and regenerates its location label without model-written markup"
                )
                let multiRuntime = TaskRuntimeSpec(
                    sources: ["Asia/Hong_Kong", "Europe/London", "America/New_York"].enumerated().flatMap { i, zone in
                        [
                            TaskDataSource(key: "time\(i)", kind: .clock, format: .time, timeZone: zone),
                            TaskDataSource(key: "date\(i)", kind: .clock, format: .date, timeZone: zone),
                        ]
                    })
                let multiID = UUID()
                model.publishTaskSurface(
                    try TaskSurface(
                        title: "World clock", markup: BuiltinCards.clock(multiRuntime), fields: [], actions: [],
                        state: [:], runtime: multiRuntime, preset: "clock"
                    ).validated(), id: multiID)
                model.activeRequest = nil
                model.selectTask(multiID, expanded: true)
                let multiCard = try await rendered(
                    ".clock-preset", ready: "document.querySelectorAll('.clock-place').length===3")
                try await inspect(multiCard, name: "clock-multiple")
                model.configureClock(multiID, fields: ["clockZone0": "Europe/London"])
                model.configureClock(multiID, fields: ["clockZone0": "Asia/Tokyo"])
                let multiSources = model.sideTasks.first(where: { $0.id == multiID })!.taskSurface!.runtime!.sources
                try check(
                    multiSources[0].timeZone == "Asia/Tokyo" && multiSources[1].timeZone == "Asia/Tokyo"
                        && multiSources[2].timeZone == "Europe/London" && multiSources[3].timeZone == "Europe/London",
                    "Changing one clock preserves other clocks even after two shared a zone")
                model.agent.interpretationOverride = nil
                model.agent.completionOverride = nil
                model.activeRequest = nil
                var edited = reusedClock.presentation
                edited.css += ".clock-time{font-size:28px}"
                try model.applyInterfaceRevision(reusedClock.id, markup: edited, original: reusedClock)
                try check(
                    model.sideTasks.first(where: { $0.id == reusedClock.id })?.taskSurface?.preset == nil,
                    "A user-edited clock becomes a saved custom design and cannot be overwritten by the preset")
                model.configureClock(reusedClock.id, fields: ["clockZone0": "Asia/Tokyo"])
                let customClock = model.sideTasks.first(where: { $0.id == reusedClock.id })!
                try check(
                    customClock.presentation.hasSameDesign(as: edited)
                        && customClock.state["clockLocationLabel"] == "Tokyo",
                    "User-edited clock keeps its design while its zone control and compact label update")

                model.collapse()
                _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
                let observation = try await model.observation()
                guard let music = BuiltinCards.music(observation: observation) else {
                    throw AppError.message("Music preset unavailable")
                }
                try check(
                    music.reusableTransport, "Music preset remains reusable across track URLs without frozen metadata")
                var ad = observation
                ad["adPlaying"] = true
                try check(BuiltinCards.music(observation: ad) == nil, "Ads cannot qualify as a ready music preset")
                model.install(music)
                model.hasCustomSurface = true
                model.beginBackgroundListening()
                model.upsertWebTask(music)
                model.selectTask(model.browser.id, expanded: true)
                let musicCard = try await rendered(".music-preset")
                _ = try await musicCard.evaluateJavaScript("document.querySelector('[data-action=playback]').click()")
                try await Task.sleep(for: .milliseconds(350))
                let playing =
                    try await model.browser.webView.evaluateJavaScript("!document.querySelector('audio').paused")
                    as? Bool
                _ = try await musicCard.evaluateJavaScript("document.querySelector('[data-action=playback]').click()")
                try await Task.sleep(for: .milliseconds(350))
                let toggledPlaying =
                    try await model.browser.webView.evaluateJavaScript("!document.querySelector('audio').paused")
                    as? Bool
                try check(
                    playing != toggledPlaying,
                    "Music playback control toggles the actual source player in both directions")
                let mutedBefore =
                    try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').muted") as? Bool
                _ = try await musicCard.evaluateJavaScript("document.querySelector('[data-action=sound]').click()")
                try await Task.sleep(for: .milliseconds(500))
                let mutedAfter =
                    try await model.browser.webView.evaluateJavaScript("document.querySelector('audio').muted") as? Bool
                try check(mutedBefore != mutedAfter, "Built-in sound control changes the actual player")
                try await inspect(musicCard, name: "music-light")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(350))
                try await inspect(musicCard, name: "music-dark")
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: .prettyPrinted)
                    .write(to: URL(fileURLWithPath: "/tmp/orvlet-builtin-cards-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                )
                .write(to: URL(fileURLWithPath: "/tmp/orvlet-builtin-cards-checks.json"))
                exit(1)
            }
        }
    }
#endif
