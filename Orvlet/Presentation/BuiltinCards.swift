import Foundation

/// Semantic slots chosen with the source recipe, never guessed from a title or URL.
struct DataCardPreset: Codable {
    enum Kind: String, Codable { case weather, currency }
    var kind: Kind
    var primaryKey: String
    var unitKey: String? = nil
    var contextKey: String? = nil

    func validate(keys: Set<String>, rows: [APIDataOutput]) throws {
        guard rows.contains(where: { $0.key == primaryKey }),
            Set([primaryKey, unitKey, contextKey].compactMap { $0 }).isSubset(of: keys)
        else {
            throw AppError.message(
                "Card slots must refer to available live fields; the primary value must be a displayed output.")
        }
    }
    static let schema: [String: Any] = [
        "type": "object",
        "description":
            "Use a built-in Pearl & Ink card for ordinary weather or currency requests. Supply live state keys, not literal values. Omit for other tasks or bespoke compositions.",
        "properties": [
            "kind": ["type": "string", "enum": ["weather", "currency"]],
            "primaryKey": [
                "type": "string",
                "description": "Main displayed field/output: temperature for weather, converted amount for currency.",
            ],
            "unitKey": [
                "type": "string", "description": "Optional source field containing the unit or quote currency.",
            ],
            "contextKey": [
                "type": "string",
                "description":
                    "Optional actual source/input field identifying the place or currency pair. Never invent a location label.",
            ],
        ], "required": ["kind", "primaryKey"],
    ]
}

enum BuiltinCards {
    static let categories = ["Music", "Clock", "Weather", "Currency", "Timer", "Calendar"]
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static func music(observation: [String: Any]) -> SurfacePlan? {
        guard observation["hasMedia"] as? Bool == true, observation["mediaPrimary"] as? Bool != false,
            observation["adPlaying"] as? Bool != true
        else { return nil }
        let markup = CardMarkup(
            html: """
                <section class='calm-surface music-preset'>
                  <div class='music-heading'><small class='calm-label' data-bind='status'></small><strong class='calm-title' data-bind='title'></strong></div>
                  <div class='calm-actions'><button class='calm-primary' data-action='playback' data-bind='toggleLabel'></button><button class='calm-secondary' data-action='sound' data-bind='muteLabel'></button></div>
                </section>
                """,
            compactHTML: "<div class='calm-glance'><span data-bind='title'></span></div>",
            css:
                ".calm-surface.music-preset{gap:20px}.music-heading{display:grid;gap:8px}.music-heading>.calm-label:empty{display:none}.music-preset .calm-title{font-size:20px;line-height:1.35}.music-preset .calm-actions{justify-content:space-between}.music-preset .calm-primary{min-width:100px}",
            height: 130)
        return try? SurfacePlan(
            components: [], width: 300, height: 130, markup: markup,
            actions: [
                BoundCardAction(id: "playback", binding: PageBinding(action: "media", operation: "toggle")),
                BoundCardAction(id: "sound", binding: PageBinding(action: "media", operation: "toggleMute")),
            ], readings: []
        ).validated(observation: observation)
    }

    static func clock(_ runtime: TaskRuntimeSpec, interactive: Bool = false) throws -> CardMarkup {
        let clocks = runtime.sources.filter { $0.kind == .clock && $0.format == .time }
        guard (1...3).contains(clocks.count), runtime.refresh == nil,
            runtime.sources.allSatisfy({ $0.kind == .clock && [.time, .date].contains($0.format) })
        else {
            throw AppError.message(
                "The clock preset supports one to three live clocks and optional dates. Use a custom interface for other time tools."
            )
        }
        let rows = clocks.enumerated().map { index, clock in
            let zone = clock.timeZone ?? TimeZone.current.identifier
            let label =
                zone.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? zone
            let date = runtime.sources.first {
                $0.format == .date && ($0.timeZone ?? TimeZone.current.identifier) == zone
            }
            let zones = Array(
                Set([
                    zone, TimeZone.current.identifier, "UTC", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo",
                    "Asia/Singapore", "Asia/Seoul", "Asia/Kolkata", "Asia/Dubai", "Europe/London", "Europe/Paris",
                    "Europe/Berlin", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
                    "America/Toronto", "America/Sao_Paulo", "Australia/Sydney", "Pacific/Auckland",
                ])
            ).sorted()
            let heading =
                interactive
                ? "<label class='clock-zone'><select aria-label='Time zone " + String(index + 1)
                    + "' data-field='clockZone" + String(index)
                    + "' data-change='configureClock'>"
                    + zones.map {
                        "<option value='" + escape($0) + "'>"
                            + escape(
                                ($0.split(separator: "/").last.map(String.init) ?? $0).replacingOccurrences(
                                    of: "_", with: " "))
                            + "</option>"
                    }.joined() + "</select></label>" : "<small class='clock-label'>" + escape(label) + "</small>"
            return "<div class='clock-place'>" + heading + "<strong class='clock-time' data-bind='" + clock.key
                + "'></strong>"
                + (date.map { "<span class='calm-description' data-bind='" + $0.key + "'></span>" } ?? "") + "</div>"
        }.joined()
        return CardMarkup(
            html: "<section class='calm-surface clock-preset'>" + rows
                + (interactive
                    ? "<label class='clock-format'><span class='calm-label'>Time format</span><span class='clock-zone'><select aria-label='Time format' data-field='clockHourStyle' data-change='configureClock'><option value='24h'>24 hour</option><option value='12h'>12 hour</option></select></span></label>"
                    : "") + "</section>",
            compactHTML: "<div class='calm-glance'><strong class='calm-value' data-bind='" + clocks[0].key
                + "'></strong>"
                + (interactive
                    ? "<small class='calm-label' data-bind='clockLocationLabel'></small>"
                    : "<small class='calm-label'>"
                        + escape(
                            (clocks[0].timeZone ?? TimeZone.current.identifier).split(separator: "/").last.map(
                                String.init)?.replacingOccurrences(of: "_", with: " ") ?? "Local") + "</small>")
                + "</div>",
            css:
                ".calm-surface.clock-preset{gap:12px}.clock-zone{display:grid;grid-template-columns:minmax(0,1fr) 24px}.clock-zone select{grid-area:1/1/2/3;padding-right:26px}.clock-zone::after{content:'⌄';grid-area:1/2;align-self:center;justify-self:center;color:var(--muted);pointer-events:none}.clock-preset select{appearance:none;-webkit-appearance:none;border-radius:10px;padding:7px 10px;min-height:34px;line-height:18px}.clock-place select{width:100%}.clock-preset:has(.clock-place:nth-child(3)){gap:6px}.clock-format{display:flex;align-items:center;justify-content:space-between;gap:12px}.clock-format select{width:110px;font-size:11px}.clock-place select{font-size:12px}.clock-preset:has(.clock-place:nth-child(3)) .clock-place{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:3px;padding-top:4px;align-items:baseline}.clock-preset:has(.clock-place:nth-child(3)) .clock-zone{grid-column:1/-1}.clock-preset:has(.clock-place:nth-child(3)) .calm-description{font-size:10px}.clock-preset:has(.clock-place:nth-child(3)) .clock-time{font-size:26px}.clock-place{display:grid;gap:6px}.clock-label{font-size:12px;font-weight:500;color:var(--muted)}.clock-place+.clock-place{border-top:1px solid var(--line);padding-top:14px}.clock-time{font-size:32px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-1px;line-height:1.2}.clock-place:only-child .clock-time{font-size:44px;letter-spacing:-1.5px}.clock-place>.calm-description{font-size:11px}",
            height: clocks.count == 3 ? 320 : clocks.count == 2 ? 245 : 185)
    }

    static func timer(finished: Bool) -> CardMarkup {
        CardMarkup(
            html:
                "<section class='calm-surface timer-preset'><div class='timer-heading'><small class='calm-label' data-bind='status'></small><strong class='timer-digits' data-bind='remaining'></strong><span class='calm-description' data-bind='timerDuration'></span></div><div class='calm-actions'><button class='calm-primary' data-action='toggle' data-bind='toggleLabel'></button>"
                + (finished
                    ? ""
                    : "<button class='calm-secondary' data-action='addMinute'>+1 min</button><button class='calm-secondary' data-action='restart'>Restart</button>")
                + "</div></section>",
            compactHTML: "<div class='calm-glance'><strong class='calm-value' data-bind='remaining'></strong></div>",
            css:
                ".calm-surface.timer-preset{gap:20px}.timer-heading{display:grid;gap:8px}.timer-digits{font-size:48px;line-height:1.1;letter-spacing:-1.5px;font-weight:600;font-variant-numeric:tabular-nums}.timer-heading>.calm-description:empty{display:none}.timer-preset .calm-primary{min-width:100px}",
            height: 185)
    }
    static func calendar(structured: Bool) -> CardMarkup {
        let schedule =
            structured
            ? "<div class='event-date'><strong data-bind='eventDate'></strong><span data-bind='eventTime'></span></div><small class='calm-label' data-bind='eventZone'></small><p class='calm-description' data-bind='eventLocation'></p>"
            : "<p class='calm-description' data-bind='detail'></p>"
        return CardMarkup(
            html:
                "<section class='calm-surface calendar-preset'><small class='calm-label' data-bind='status'></small><div class='event-heading'><strong class='calm-title' data-bind='title'></strong>"
                + schedule
                + "</div><div class='calm-actions'><button class='calm-secondary' data-action='calendar'>Open Calendar</button></div></section>",
            compactHTML: "<div class='calm-glance'><strong class='calm-value' data-bind='"
                + (structured ? "eventTime" : "title") + "'></strong>"
                + (structured ? "<small class='calm-label' data-bind='eventDate'></small>" : "") + "</div>",
            css:
                ".calm-surface.calendar-preset{gap:16px}.event-heading{display:grid;gap:8px}.event-date{display:grid;gap:3px}.event-date strong{font-size:13px;font-weight:500}.event-date span{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.3px}.event-heading>p:empty,.event-heading>small:empty{display:none}.event-heading .calm-description{white-space:pre-line}",
            height: 240)
    }
    static func data(
        _ preset: DataCardPreset, rows: [APIDataOutput], inputs: [String], footer: String, swap: Bool,
        dateKey: String? = nil, conditionKey: String? = nil, lowKey: String? = nil
    )
        -> CardMarkup
    {
        let primary = rows.first { $0.key == preset.primaryKey }!
        let unit = preset.unitKey ?? primary.unitKey
        let value = "<span data-bind='" + primary.key + "'></span>"
        let unitHTML =
            unit.map { "<span class='preset-unit' data-bind='" + $0 + "'></span>" } ?? primary.unit.map {
                "<span class='preset-unit'>" + escape($0) + "</span>"
            } ?? ""
        let context = preset.contextKey.map { "<strong class='preset-place' data-bind='" + $0 + "'></strong>" } ?? ""
        let details = rows.filter {
            $0.key != primary.key && $0.key != unit && $0.key != preset.contextKey && $0.key != dateKey
                && $0.key != conditionKey && $0.key != lowKey
        }.map {
            row in
            "<div class='preset-detail'><span class='calm-label'>" + escape(row.label) + "</span><strong data-bind='"
                + row.key + "'></strong>"
                + (row.unitKey.map { "<span data-bind='" + $0 + "'></span>" } ?? row.unit.map {
                    "<span>" + escape($0) + "</span>"
                } ?? "") + "</div>"
        }.joined()
        let low =
            rows.first { $0.key == lowKey }.map { row in
                "<span class='weather-low calm-description'>Low <span data-bind='" + row.key + "'></span> "
                    + (row.unitKey.map { "<span data-bind='" + $0 + "'></span>" } ?? escape(row.unit ?? "")) + "</span>"
            } ?? ""
        let number = "<div class='preset-number'>" + value + unitHTML + "</div>"
        let hero: String
        if preset.kind == .weather {
            hero =
                "<div class='preset-result'><div class='weather-heading'>" + context
                + (dateKey.map { "<small class='calm-label' data-bind='" + $0 + "'></small>" } ?? "")
                + "</div><div class='weather-reading'><div><small class='calm-label'>" + escape(primary.label)
                + "</small>" + number + low + "</div>"
                + (conditionKey.map {
                    "<div class='weather-condition'><span class='calm-description' data-bind='" + $0
                        + "'></span><small class='calm-label' data-bind='weatherSampleTime'></small></div>"
                } ?? "")
                + "</div></div>"
        } else {
            hero = "<div class='preset-result'><small class='calm-label'>Converted amount</small>" + number + "</div>"
        }
        let controls: String
        if preset.kind == .currency, inputs.count == 3, swap {
            controls =
                "<div class='preset-inputs currency-inputs'>" + inputs[0] + inputs[1]
                + "<button class='calm-secondary currency-swap' data-action='swapCurrencies' aria-label='Swap currencies' title='Swap currencies'>⇄</button>"
                + inputs[2] + "</div>"
        } else {
            controls = inputs.isEmpty ? "" : "<div class='preset-inputs'>" + inputs.joined() + "</div>"
        }
        return CardMarkup(
            html: "<section class='calm-surface data-preset " + preset.kind.rawValue + "-preset'>"
                + controls + hero
                + "<div class='preset-details'>" + details + "</div>" + footer + "</section>",
            compactHTML: "<div class='calm-glance'><strong class='calm-value'>" + value + " " + unitHTML
                + "</strong><small class='calm-label'>"
                + (preset.kind == .weather
                    ? escape(primary.label)
                        + (preset.contextKey.map { " · <span data-bind='" + $0 + "'></span>" } ?? "")
                    : "<span data-bind='currencyPair'></span>") + "</small></div>",
            css: """
                .calm-surface.data-preset{gap:14px}.data-preset.currency-preset{gap:12px}.preset-result{display:grid;gap:6px}.preset-place{font-size:16px;font-weight:500;line-height:1.3}.preset-number{display:flex;flex-wrap:wrap;align-items:baseline;gap:7px;font-size:32px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-1px;line-height:1.15;overflow-wrap:anywhere}.preset-unit{font-size:14px;font-weight:500;letter-spacing:0;color:var(--muted)}.data-preset.weather-preset{gap:8px}.weather-low{display:block;margin-top:3px}.weather-heading,.weather-reading{display:flex;align-items:baseline;justify-content:space-between;gap:12px}.weather-condition{display:grid;gap:4px;max-width:125px;text-align:right}.weather-condition small:empty{display:none}.weather-heading small{white-space:nowrap}.weather-preset .preset-number{font-size:36px;letter-spacing:-1px}.weather-preset .preset-result{gap:4px}.weather-preset .preset-details{gap:8px 16px}.weather-preset .preset-place{font-size:13px}.weather-preset .preset-inputs{grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:10px}.weather-preset .data-input input,.weather-preset .data-input select{font-size:12px}.weather-preset .preset-unit{font-size:22px}.preset-inputs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.data-input{display:grid;gap:6px;align-content:start;min-width:0}.data-input>span{font-size:11px;font-weight:500;color:var(--muted)}.data-input input,.data-input select{min-width:0;width:100%;font-size:14px}.currency-preset .data-input:first-child{grid-column:1/-1}.currency-preset .data-input:first-child input{font-size:22px;font-weight:500;letter-spacing:-.5px;font-variant-numeric:tabular-nums;padding:7px 12px;min-height:44px;background:transparent}.currency-preset input::-webkit-inner-spin-button,.currency-preset input::-webkit-outer-spin-button{-webkit-appearance:none;margin:0}.currency-inputs{grid-template-columns:minmax(0,1fr) 32px minmax(0,1fr);column-gap:10px;row-gap:10px}.currency-swap{align-self:start;margin-top:22px;padding:0;font-size:20px;min-width:32px;min-height:36px}.currency-name{font-size:10px;line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;color:var(--muted)}.data-input select{appearance:none;-webkit-appearance:none;min-height:36px;padding:7px 26px 7px 10px}.data-input:has(select){grid-template-columns:minmax(0,1fr) 22px;column-gap:0}.data-input:has(select)>span,.data-input:has(select)>small{grid-column:1/-1}.data-input select{grid-area:2/1/3/3}.data-input:has(select)::after{content:'⌄';grid-area:2/2/3/3;align-self:center;justify-self:center;font-size:14px;color:var(--muted);pointer-events:none}.preset-details{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 16px}.preset-detail{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px;font-size:13px}.preset-detail>.calm-label{flex-basis:100%}.preset-detail strong{font-size:14px;font-weight:500;overflow-wrap:anywhere}.preset-detail:only-child{grid-column:1/-1}.data-preset>small:empty,.preset-details:empty{display:none}.data-preset>small{font-size:11px;color:var(--muted)}.data-preset footer{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:3px 12px;align-items:center;border-top:1px solid var(--line);padding-top:10px;font-size:10px;color:var(--muted)}.data-preset footer>span:empty{display:none}.data-preset footer>span{overflow-wrap:anywhere;line-height:1.4}.data-preset footer>span:nth-child(2){grid-column:1}.data-preset footer button{grid-column:2;grid-row:1/3;min-height:32px}
                """, height: preset.kind == .currency ? 310 : 305)
    }
}
