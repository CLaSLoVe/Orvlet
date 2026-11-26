import Foundation

/// Public intent -> private executable recipe. Only this compiler owns state keys,
/// control wiring, output contracts, calculation envelopes and the two card views.
@MainActor
enum DataToolPlan {
    static let schema = ToolSchema.function("build_data_tool",
        "Prepare a retained result and reusable operations from an inspected source. Declare each parameter once. A result selects a binding with value; only derived results need a JavaScript expression. The host owns state, calculation wrappers, units and refresh operations. Use present_results afterward to choose views. No HTML, output keys or action handlers. The first result is the primary reading. Expressions receive input and data as scalar strings; use Number for arithmetic.",
        [
            "source": ["type":"string", "description":"Observation handle or URL returned by inspect_api in this request."],
            "title": ["type":"string", "maxLength":80],
            "subject": ["type":"string", "maxLength":80, "description":"Recognizable object/activity for the capsule. May contain {parameter} or {binding} names."],
            "url": ["type":"string", "description":"Only if parameters change the request: the observed URL with {parameter} placeholders in its path/query. Its initial expansion must equal the observed request."],
            "parameters": ["type":"object", "maxProperties":8, "additionalProperties": ["type":"object", "properties":[
                "label":["type":"string","maxLength":60],
                "value":["type":["string","number"]],
                "options":["type":"array","maxItems":250,"items":["type":"string","minLength":1,"maxLength":80]],
                "choicesFrom":["type":"string","description":"JSON pointer to an observed object whose keys are supported choices, or an array of strings."],
                "catalog":["type":"string","enum":ChoiceCatalog.allCases.map(\.rawValue)],
                "verifyAt":["type":"string","description":"Optional JSON pointer when the source echoes this request parameter's identity. Local calculation inputs need no source assertion."],
            ],"required":["label","value"]]],
            "bindings": ["type":"object", "maxProperties":10, "additionalProperties":["type":"string"],
                "description":"Named source values: each value is an exact JSON pointer, optionally containing {parameter}. Expressions read data.name. No copied remote numbers."],
            "verify": ["type":"object", "maxProperties":6, "additionalProperties":["type":"string"],
                "description":"Optional identity assertions: a declared binding name or JSON pointer -> expected value, optionally {parameter}. These assertions apply to the source, not generated labels."],
            "results": ["type":"array","minItems":1,"maxItems":6,"items":["type":"object","properties":[
                "label":["type":"string","maxLength":80],
                "value":["type":"string","description":"Declared binding name for a direct source reading. Choose this or expression, not both."],
                "expression":["type":"string","maxLength":2000,"description":"One JS expression, e.g. Number(data.available) / Number(input.groupSize). No return statement or state wrapper."],
                "unit":["type":"string","maxLength":40,"description":"Documented fixed unit, or {parameter}/{binding} for a changing unit."],
                "decimals":["type":"integer","minimum":0,"maximum":8],
            ],"required":["label"]]],
            "updatedAt":["type":"string","description":"Optional pointer to the source's publication/update timestamp. Standard timestamp formats are parsed by the host."],
            "refreshSeconds":["type":"number","minimum":15,"maximum":86400],
            "reminder": CardReminderRule.schema(forKeyDescription: "A named binding or computed output (result0, result1, …). Set refreshSeconds to observe changes in the background."),
            "complete":["type":"boolean"],
        ], required:["source","title","bindings","results"])

    static func compile(_ plan: [String:Any], sample: APIDataService.Sample) throws -> APIDataSpec {
        let parameters = plan["parameters"] as? [String:[String:Any]] ?? [:]
        let bindings = plan["bindings"] as? [String:String] ?? [:]
        let results = plan["results"] as? [[String:Any]] ?? []
        let title = plan["title"] as? String ?? ""
        func issue(_ path: String, _ text: String) -> ToolArgumentError { .init(path:path,issue:text) }
        func identifier(_ name: String) -> Bool { name.range(of:#"^[A-Za-z][A-Za-z0-9_]{0,30}$"#,options:.regularExpression) != nil }
        guard !title.isEmpty, !bindings.isEmpty, (1...6).contains(results.count),
            parameters.keys.allSatisfy(identifier), bindings.keys.allSatisfy(identifier) else {
            throw issue("$.bindings", "use named source bindings and at least one result")
        }
        let inputNames = parameters.keys.sorted()
        let fieldNames = bindings.keys.sorted()
        let inputKeys = Dictionary(uniqueKeysWithValues: inputNames.enumerated().map { ($0.element,"p" + String($0.offset)) })
        let fieldKeys = Dictionary(uniqueKeysWithValues: fieldNames.enumerated().map { ($0.element,"f" + String($0.offset)) })
        var inputs: [String:String] = [:]
        var controls: [APIDataControl] = []
        var fields: [APIDataField] = []
        var expectations: [String:String] = [:]
        func template(_ text: String) -> String {
            var result = text
            for name in inputNames { result = result.replacingOccurrences(of:"{" + name + "}",with:"{" + inputKeys[name]! + "}") }
            return result
        }
        func defaultExpanded(_ text: String) -> String {
            var result = text
            for name in inputNames {
                if let value = APIDataSpec.scalar(parameters[name]?["value"]) {
                    result = result.replacingOccurrences(of:"{" + name + "}",with:value)
                }
            }
            return result
        }
        func sourcePointer(_ text: String) -> String {
            var result = text
            for name in inputNames {
                if let value = APIDataSpec.scalar(parameters[name]?["value"]) {
                    result = result.replacingOccurrences(of:"{" + name + "}",with:value.replacingOccurrences(of:"~",with:"~0").replacingOccurrences(of:"/",with:"~1"))
                }
            }
            return result
        }
        func canonicalPointer(_ reference: String) -> String {
            let pointer = bindings[reference] ?? reference
            let expanded = sourcePointer(pointer)
            return sample.sourcePointer(expanded) == expanded ? pointer : String(pointer.dropFirst(5))
        }
        for name in fieldNames {
            let pointer = canonicalPointer(bindings[name]!)
            guard APIDataSpec.scalar(APIDataSpec.value(sourcePointer(pointer),in:sample.response)) != nil else {
                throw issue("$.bindings." + name, "select an actual scalar in the inspected response")
            }
            fields.append(.init(key:fieldKeys[name]!,label:name,pointer:template(pointer)))
        }
        func assertion(_ pointer: String, expected: String, path: String) throws {
            let pointer = canonicalPointer(pointer)
            let actualPointer = sourcePointer(pointer)
            guard let actual = APIDataSpec.scalar(APIDataSpec.value(actualPointer,in:sample.response)),
                actual.caseInsensitiveCompare(defaultExpanded(expected)) == .orderedSame else {
                throw issue(path,"the inspected source does not report the expected identity at this pointer")
            }
            let internalPointer = template(pointer)
            let key: String
            if let field = fields.first(where: { $0.pointer == internalPointer }) { key = field.key }
            else {
                key = "proof" + String(fields.count)
                fields.append(.init(key:key,label:"Source identity",pointer:internalPointer))
            }
            if let prior = expectations[key], prior != template(expected) {
                throw issue(path,"conflicting identity assertions for the same source field")
            }
            expectations[key] = template(expected)
        }
        let request = plan["url"] as? String ?? sample.url
        for name in inputNames {
            let p = parameters[name]!, key = inputKeys[name]!
            guard let value = APIDataSpec.scalar(p["value"]), let label = p["label"] as? String, !label.isEmpty else {
                throw issue("$.parameters." + name,"provide a label and scalar initial value")
            }
            inputs[key] = value
            var options = p["options"] as? [String]
            if let pointer = p["choicesFrom"] as? String {
                let raw = APIDataSpec.value(sourcePointer(canonicalPointer(pointer)),in:sample.response)
                if let object = raw as? [String:Any] { options = object.keys.sorted() }
                else if let values = raw as? [String] { options = values }
                else { throw issue("$.parameters." + name + ".choicesFrom","select an observed object or array of strings") }
                guard options!.count <= 250 else { throw issue("$.parameters." + name + ".choicesFrom","narrow the supported choices to at most 250") }
            }
            let catalog = (p["catalog"] as? String).flatMap(ChoiceCatalog.init(rawValue:))
            let sourceBound = request.contains("{" + name + "}") || bindings.values.contains { $0.contains("{" + name + "}") }
            if sourceBound, let pointer = p["verifyAt"] as? String {
                try assertion(pointer,expected:"{" + name + "}",path:"$.parameters." + name + ".verifyAt")
            }
            let kind = options?.isEmpty == false || catalog != nil ? "select" : Double(value) == nil ? "text" : "number"
            let control = APIDataControl(key:key,label:label,kind:kind,options:options,catalog:catalog)
            guard kind != "select" || control.accepts(value) else {
                throw issue("$.parameters." + name + ".value","choose a value from the declared supported choices")
            }
            controls.append(control)
        }
        let changingRecord = inputNames.contains { name in
            request.contains("{" + name + "}") || bindings.values.contains { $0.contains("{" + name + "}") }
        }
        let measuredPointers = Set(results.compactMap { $0["value"] as? String }.map(canonicalPointer))
        let identityPointers = Set(parameters.values.compactMap { $0["verifyAt"] as? String }.map(canonicalPointer))
        for (pointer,expected) in (plan["verify"] as? [String:String] ?? [:]).sorted(by:{$0.key < $1.key}) {
            // A value selected for display is not an invariant of every future
            // record. Parameter identity checks remain enforced independently.
            let path = canonicalPointer(pointer)
            if changingRecord, measuredPointers.contains(path), !identityPointers.contains(path),
                !inputNames.contains(where:{ expected.contains("{" + $0 + "}") }) { continue }
            try assertion(pointer,expected:expected,path:"$.verify")
        }
        guard fields.count <= APIDataSpec.maximumSourceFields else {
            throw issue("$.bindings","select at most \(APIDataSpec.maximumSourceFields) source values including identity assertions")
        }
        guard fields.count + results.count + 1 <= APIDataSpec.maximumValues else {
            throw issue("$.results","reduce source bindings or results to fit \(APIDataSpec.maximumValues - 1) values; the host reserves one identity value")
        }
        func displayExpression(_ text: String) throws -> String {
            let regex = try NSRegularExpression(pattern:#"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
            var parts: [String] = [], offset = text.startIndex
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                let range = Range(match.range,in:text)!, nameRange = Range(match.range(at:1),in:text)!
                parts.append(JSONText.encode(String(text[offset..<range.lowerBound])))
                let name = String(text[nameRange])
                guard let key = inputKeys[name] ?? fieldKeys[name] else { throw issue("$.subject","unknown display binding " + name) }
                parts.append("String(state[" + JSONText.encode(key) + "] ?? input[" + JSONText.encode(key) + "] ?? '')")
                offset = range.upperBound
            }
            parts.append(JSONText.encode(String(text[offset...])))
            return parts.joined(separator:" + ")
        }
        var outputs: [APIDataOutput] = []
        let dataObject = fieldNames.map { JSONText.encode($0) + ":state[" + JSONText.encode(fieldKeys[$0]!) + "]" }.joined(separator:",")
        let inputObject = inputNames.map { JSONText.encode($0) + ":input[" + JSONText.encode(inputKeys[$0]!) + "]" }.joined(separator:",")
        var code = "const data={" + dataObject + "}; const params={" + inputObject + "}; const result={};\n"
        for (index,row) in results.enumerated() {
            let key = "result" + String(index)
            guard let label = row["label"] as? String, !label.isEmpty else { throw issue("$.results[\(index)].label","provide a result label") }
            let expression: String
            if let binding = row["value"] as? String {
                guard fieldKeys[binding] != nil, row["expression"] == nil else {
                    throw issue("$.results[\(index)].value","choose one declared binding, without an expression")
                }
                expression = "data[" + JSONText.encode(binding) + "]"
            } else if let calculation = row["expression"] as? String, !calculation.isEmpty {
                expression = calculation
            } else { throw issue("$.results[\(index)]","select a binding with value, or supply an expression for a derived result") }
            var output = APIDataOutput(key:key,label:label)
            if let unit = row["unit"] as? String, !unit.isEmpty {
                if unit.hasPrefix("{"), unit.hasSuffix("}"), let reference = inputKeys[String(unit.dropFirst().dropLast())] ?? fieldKeys[String(unit.dropFirst().dropLast())] {
                    output.unitKey = reference
                } else {
                    guard !unit.contains("{"), unit.count <= 20 else { throw issue("$.results[\(index)].unit","use a fixed unit or one declared {binding}") }
                    output.unit = unit
                }
            }
            outputs.append(output)
            let decimals = row["decimals"] as? Int
            code += "try { const value=((input,data)=>(" + expression + "))(params,data); "
            code += "if(value===null || value===undefined || typeof value==='object' || (typeof value==='number' && !Number.isFinite(value))) throw Error('Expected a finite scalar'); "
            if let decimals { code += "if(!Number.isFinite(Number(value))) throw Error('Expected a number'); result." + key + "=Number(value).toFixed(\(decimals)); " }
            else { code += "result." + key + "=String(value); " }
            code += "} catch(e) { throw Error('results[\(index)].expression: '+e.message); }\n"
        }
        let subject = plan["subject"] as? String ?? title
        outputs.append(.init(key:"toolSubject",label:"Object"))
        code += "result.toolSubject=" + (try displayExpression(subject)) + "; return {state:result};"
        var spec = APIDataSpec(url:template(request),fields:fields,updatedAtPointer:(plan["updatedAt"] as? String).map { template(canonicalPointer($0)) },
            inputs:inputs,controls:controls,calculation:code,outputs:outputs,expectations:expectations,
            refreshSeconds:plan["refreshSeconds"] as? Double,
            card:DataCardPreset(kind:.reading,primaryKey:"result0",unitKey:outputs.first?.unitKey,
                subject:title,detailKeys:Array(outputs.dropFirst().dropLast().map(\.key)),displayNameKey:"toolSubject"))
        if var rule = try CardReminderRule.decode(plan["reminder"]) {
            rule.key = fieldKeys[rule.key] ?? inputKeys[rule.key] ?? rule.key
            spec.reminder = rule
        }
        if let binding = results.first?["value"] as? String, let pointer = bindings[binding] {
            spec.primarySourcePointer = canonicalPointer(pointer)
        }
        // Never treat a different endpoint as the observed response.
        let observed = URLComponents(string:sample.url)
        let requestPath = String(request.split(separator:"?",maxSplits:1,omittingEmptySubsequences:false)[0])
        spec.pathParameters = inputNames.compactMap { name in
            guard let value = APIDataSpec.scalar(parameters[name]?["value"]), value.contains("/"),
                requestPath.contains("{" + name + "}"),
                observed?.percentEncodedPath.contains(value) == true else { return nil }
            return inputKeys[name]
        }
        let expanded = URLComponents(url:try spec.requestURL(),resolvingAgainstBaseURL:false)
        func query(_ c: URLComponents?) -> [String] { (c?.queryItems ?? []).map { $0.name + "=" + ($0.value ?? "") }.sorted() }
        guard observed?.scheme == expanded?.scheme, observed?.host == expanded?.host,
            observed?.port == expanded?.port, observed?.percentEncodedPath == expanded?.percentEncodedPath, query(observed) == query(expanded) else {
            throw issue("$.url","initial parameters must reproduce the inspected request")
        }
        // Parameter-based units are host-owned display values, not claims of source evidence.
        spec = try spec.validated()
        return spec
    }
}
