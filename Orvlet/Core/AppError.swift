import Foundation

/// A displayable application error. Domain-specific errors retain their own types.
nonisolated enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
