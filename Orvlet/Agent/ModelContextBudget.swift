import Foundation

/// Local estimate for compatible providers with different tokenizers. Images
/// are charged as vision inputs rather than as their base64 transport text.
enum ModelContextBudget {
    static let defaultWindow = 128_000

    static func tokens(_ text: String) -> Int {
        (text.utf8.count + 1) / 2
    }

    static func estimate(_ value: Any) -> Int {
        if let text = value as? String { return tokens(text) + 1 }
        if let fields = value as? [String: Any] {
            if ["image", "image_url", "input_image"].contains(fields["type"] as? String ?? "") { return 2048 }
            return fields.reduce(2) { $0 + tokens($1.key) + 2 + estimate($1.value) }
        }
        if let items = value as? [Any] { return items.reduce(2) { $0 + estimate($1) + 1 } }
        return 4
    }

    static func limit(_ body: [String: Any], options: ModelOptions) throws -> Int {
        let window = options.contextWindow.flatMap(Int.init) ?? defaultWindow
        let fields = ["max_output_tokens", "max_completion_tokens", "max_tokens", options.tokenParameter]
        let reserve = fields.compactMap { body[$0] as? Int }.max() ?? min(4096, window / 4)
        guard reserve >= 0, window > reserve else {
            throw AppError.message("The output token limit leaves no room for input. Adjust this model’s token limits in Settings.")
        }
        return window - reserve
    }
}
