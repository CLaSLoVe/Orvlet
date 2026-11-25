import Foundation
import CoreFoundation

/// One advisory boundary for Jev and OpenAI. No tool execution or main-model
/// conversation is sent through the Decisions API.
@MainActor
enum DecisionClient {
    static func judge(endpoint: Endpoint, api: DecisionAPI, key: String, state: Any,
                      questions: [String: String], timeout: TimeInterval = 4) async throws -> [String: Double] {
        let typed = questions.mapValues { ["type": "noul", "instructions": $0] }
        let result = try await request(endpoint: endpoint, api: api, key: key, state: state, questions: typed, timeout: timeout)
        let answers = result["answers"] as? [String: [String: Any]] ?? [:]
        var values: [String: Double] = [:]
        for (name, answer) in answers {
            guard answer["type"] as? String == "noul", let value = probability(answer["noul"]) else {
                throw AppError.message("The decision service returned an invalid probability.")
            }
            values[name] = value
        }
        return values
    }
    static func request(endpoint: Endpoint, api: DecisionAPI, key: String, state: Any,
                        questions: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = api.url(for: endpoint), !endpoint.model.isEmpty else {
            throw AppError.message("Enter a decision endpoint and model in Settings.")
        }
        let payload = try body(endpoint: endpoint, api: api, state: state, questions: questions)
        let headers = try ModelWire.headers(endpoint: endpoint, key: key)
        let result = try await ModelClient.request(url: url, key: key, body: payload, timeout: timeout, headers: headers)
        return try normalize(result, api: api, questions: questions)
    }
    static func body(endpoint: Endpoint, api: DecisionAPI, state: Any, questions: [String: Any]) throws -> [String: Any] {
        guard (1...400).contains(questions.count) else { throw AppError.message("A decision request needs 1–400 questions.") }
        if api == .jev { return ["model": endpoint.model, "state": state, "questions": questions] }
        let converted: [[String: Any]] = try questions.keys.sorted().map { name in
            guard let question = questions[name] as? [String: Any], let type = question["type"] as? String,
                let instructions = question["instructions"] as? String else { throw AppError.message("Invalid decision question.") }
            var result: [String: Any] = ["name": name, "instructions": instructions]
            switch type {
            case "noul": result["type"] = "predicate"
            case "choice":
                guard let choices = question["criteria"] as? [String: String], !choices.isEmpty else { throw AppError.message("A choice needs its allowed values.") }
                result["type"] = "choice"
                result["choices"] = choices.keys.sorted().map { ["value": $0, "description": choices[$0]!] }
            default: throw AppError.message("Unsupported decision question type.")
            }
            return result
        }
        return ["model": endpoint.model, "input": [["role": "user", "content": [["type": "input_json", "data": state]]]], "questions": converted]
    }
    static func probability(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
    static func normalize(_ result: [String: Any], api: DecisionAPI, questions: [String: Any]) throws -> [String: Any] {
        if api == .jev {
            guard let answers = result["answers"] as? [String: [String: Any]], Set(answers.keys).isSubset(of: Set(questions.keys)) else {
                throw AppError.message("The decision service returned invalid answers.")
            }
            return result
        }
        guard let answers = result["answers"] as? [[String: Any]] else { throw AppError.message("OpenAI Decisions returned invalid answers.") }
        var normalized: [String: [String: Any]] = [:]
        var seen: Set<String> = []
        for answer in answers {
            guard let name = answer["name"] as? String, let question = questions[name] as? [String: Any],
                seen.insert(name).inserted, let type = answer["type"] as? String else {
                throw AppError.message("OpenAI Decisions returned an unknown or duplicate answer.")
            }
            if type == "refusal" { continue } // No fabricated confidence or actionable fallback.
            if type == "predicate", question["type"] as? String == "noul", let value = probability(answer["probability"]) {
                normalized[name] = ["type": "noul", "noul": value]
            } else if type == "choice", question["type"] as? String == "choice",
                let choice = answer["choice"] as? String, let confidence = probability(answer["confidence"]),
                let rows = answer["probabilities"] as? [[String: Any]], let criteria = question["criteria"] as? [String: String] {
                var probabilities: [String: Double] = [:]
                for row in rows {
                    guard let value = row["value"] as? String, criteria[value] != nil, probabilities[value] == nil,
                        let probability = probability(row["probability"]) else { throw AppError.message("OpenAI Decisions returned invalid choices.") }
                    probabilities[value] = probability
                }
                guard criteria[choice] != nil, Set(probabilities.keys) == Set(criteria.keys),
                    abs(probabilities.values.reduce(0, +) - 1) < 0.02 else { throw AppError.message("OpenAI Decisions returned an incomplete distribution.") }
                normalized[name] = ["type": "choice", "choice": choice, "confidence": confidence, "probabilities": probabilities]
            } else { throw AppError.message("OpenAI Decisions returned an unexpected answer type.") }
        }
        var output = result
        output["answers"] = normalized
        return output
    }
}
