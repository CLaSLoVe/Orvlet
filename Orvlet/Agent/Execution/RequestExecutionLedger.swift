import Foundation

/// Evidence belongs to an operation, not to a model's next reply.
struct ToolVerification {
    let reply: String
    var needsInput = false
    var finalCheck = false
}

@MainActor
final class ToolExecutionContext {
    var verification: ToolVerification?
    var effectStarted = false
}

enum ToolExecutionScope {
    @TaskLocal static var current: ToolExecutionContext?
}

/// One ledger per human request revision. A new request may intentionally repeat an action.
@MainActor
final class RequestExecutionLedger {
    struct Receipt {
        let result: [String: Any]
        let verification: ToolVerification?
    }
    enum Entry {
        case running(Task<Receipt, Error>)
        case succeeded(Receipt)
        case uncertain
    }
    private(set) var goals: [String] = []
    private(set) var fulfilled: [Int: Receipt] = [:]
    var entries: [String: Entry] = [:]
    var uncertainGoals = Set<Int>()
    var hasGoals: Bool { !goals.isEmpty }
    var complete: Bool { hasGoals && fulfilled.count == goals.count }

    func configure(goals: [String]) { self.goals = goals }

    func resolveGoal(_ proposed: Int?) throws -> Int? {
        if let proposed {
            guard goals.indices.contains(proposed) else {
                throw AppError.message(
                    "Choose an existing requested goal; do not invent another goal to repeat an action.")
            }
            return proposed
        }
        if goals.count == 1 { return 0 }
        return nil
    }

    func record(_ receipt: Receipt, goal: Int?) {
        guard let goal, let proof = receipt.verification, !proof.needsInput else { return }
        fulfilled[goal] = receipt
        uncertainGoals.remove(goal)
    }

    static func signature(_ name: String, _ input: [String: Any], goal: Int?) -> String {
        let effect = input.filter { !["complete", "goal"].contains($0.key) }
        let data = (try? JSONSerialization.data(withJSONObject: effect, options: [.sortedKeys])) ?? Data()
        return "\(goal.map(String.init) ?? "unassigned"):\(name):" + String(decoding: data, as: UTF8.self)
    }
}

@MainActor
extension AgentController {
    func verifyEffect(_ reply: String, needsInput: Bool = false) {
        let proof = ToolVerification(reply: reply, needsInput: needsInput)
        if let scope = ToolExecutionScope.current { scope.verification = proof } else { lastToolVerification = proof }
    }

    var effectReply: String {
        if let scope = ToolExecutionScope.current { return scope.verification?.reply ?? "" }
        return lastToolVerification?.reply ?? ""
    }

    func clearEffectVerification() {
        if let scope = ToolExecutionScope.current { scope.verification = nil } else { lastToolVerification = nil }
    }
}
