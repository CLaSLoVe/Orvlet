import Foundation

extension APIDataSpec {
    /// Only the documented wttr.in JSON schema has this migration. Unknown sources keep their declared units.
    var isWttrWeather: Bool {
        card?.kind == .weather && URLComponents(string: url)?.host?.lowercased() == "wttr.in"
    }
    var withWeatherControls: APIDataSpec {
        guard isWttrWeather, customLayout != true else { return self }
        var result = self
        let units = [
            "maxtempC": "°C", "mintempC": "°C", "avgtempC": "°C", "temp_C": "°C", "tempC": "°C", "FeelsLikeC": "°C",
            "maxtempF": "°F", "mintempF": "°F", "temp_F": "°F", "tempF": "°F", "chanceofrain": "%", "humidity": "%",
            "precipMM": "mm", "windspeedKmph": "km/h",
        ]
        for i in result.fields.indices {
            let component = result.fields[i].pointer.split(separator: "/").last.map(String.init) ?? ""
            if let unit = units[component] { result.fields[i].unit = unit }
            if ["maxtempC", "maxtempF"].contains(component) { result.fields[i].label = "High" }
            if ["mintempC", "mintempF"].contains(component) { result.fields[i].label = "Low" }
        }
        if let context = result.card?.contextKey,
            let field = result.fields.first(where: { $0.key == context }),
            field.pointer.contains("/nearest_area/"), !field.pointer.contains("/areaName/")
        {
            if let city = result.fields.first(where: { $0.pointer == "/nearest_area/0/areaName/0/value" }) {
                result.card?.contextKey = city.key
            } else if result.fields.count < 10, !result.keys.contains("weatherCity"), inputs?["weatherCity"] == nil {
                result.fields.append(
                    APIDataField(key: "weatherCity", label: "City", pointer: "/nearest_area/0/areaName/0/value"))
                result.card?.contextKey = "weatherCity"
            }
        }
        guard calculation == nil, (inputs ?? [:]).count <= 6 else { return result }
        var values = inputs ?? [:]
        var controls = inputControls
        if let parts = URLComponents(string: url), parts.path.split(separator: "/").count == 1,
            !url.contains("{"), !keys.contains("weatherLocation")
        {
            let place = String(parts.path.dropFirst()).removingPercentEncoding ?? String(parts.path.dropFirst())
            if !place.isEmpty {
                // Preserve the host and all source options; only the location path becomes editable.
                if let range = result.url.range(
                    of: parts.percentEncodedPath,
                    range: result.url.range(of: "wttr.in")!.upperBound..<result.url.endIndex)
                {
                    result.url.replaceSubrange(range, with: "/{weatherLocation}")
                    values["weatherLocation"] = place.replacingOccurrences(of: "+", with: " ").replacingOccurrences(
                        of: "_", with: " ")
                    controls.insert(APIDataControl(key: "weatherLocation", label: "City"), at: 0)
                }
            }
        }
        let dayIndices = Set(
            fields.compactMap { field -> String? in
                let parts = field.pointer.split(separator: "/")
                return parts.count > 2 && parts[0] == "weather" && ["0", "1", "2"].contains(String(parts[1]))
                    ? String(parts[1]) : nil
            })
        if dayIndices.count == 1, let day = dayIndices.first, !keys.contains("weatherDay"), values["weatherDay"] == nil
        {
            values["weatherDay"] = day
            controls.append(
                APIDataControl(key: "weatherDay", label: "Forecast", kind: "select", options: ["0", "1", "2"]))
            for i in result.fields.indices {
                result.fields[i].pointer = result.fields[i].pointer.replacingOccurrences(
                    of: "/weather/" + day + "/", with: "/weather/{weatherDay}/")
            }
        }
        result.inputs = values.isEmpty ? nil : values
        result.controls = controls.isEmpty ? nil : controls
        return result
    }
    func optionLabel(_ value: String, for key: String) -> String {
        isWttrWeather && key == "weatherDay"
            ? (["0": "Today", "1": "Tomorrow", "2": "In 2 days"][value] ?? value) : value
    }
    var weatherLowKey: String? {
        guard card?.kind == .weather else { return nil }
        return fields.first { $0.pointer.hasSuffix("/mintempC") || $0.pointer.hasSuffix("/mintempF") }?.key
    }
    var weatherDateKey: String? {
        guard card?.kind == .weather else { return nil }
        return fields.first { $0.pointer.hasSuffix("/date") }?.key
    }
    var weatherConditionKey: String? {
        guard card?.kind == .weather else { return nil }
        return fields.first { $0.pointer.contains("/weatherDesc/") || $0.pointer.hasSuffix("/condition") }?.key
    }
    var weatherHourlyKeys: Set<String> {
        Set(fields.filter { $0.pointer.contains("/hourly/") }.map(\.key))
    }
}
