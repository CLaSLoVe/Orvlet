import Foundation

enum ModelAPI: String, Codable, CaseIterable {
    case chatCompletions, responses, messages
    var title: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .messages: "Anthropic Messages"
        }
    }
    var path: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .messages: "messages"
        }
    }
}
enum ModelAuthentication: String, Codable, CaseIterable {
    case automatic, bearer, apiKey, custom, none
    var title: String {
        switch self {
        case .automatic: "Protocol default"
        case .bearer: "Bearer token"
        case .apiKey: "x-api-key"
        case .custom: "Custom header"
        case .none: "No authentication"
        }
    }
}
enum ModelReasoning: String, Codable, CaseIterable {
    case automatic, provider, none, minimal, low, medium, high, xhigh, max
    var title: String {
        switch self {
        case .automatic: "Automatic (Orvlet)"
        case .provider: "Provider default"
        default: rawValue.capitalized
        }
    }
}

struct ModelOptions: Codable, Equatable {
    var api = ModelAPI.chatCompletions
    var exactURL = false
    var allowInsecureHTTP = false
    var authentication = ModelAuthentication.automatic
    var authHeader = "api-key"
    var authPrefix = ""
    var reasoning = ModelReasoning.automatic
    var outputTokens = ""
    var tokenParameter = "max_completion_tokens"
    var temperature = ""
    var timeout = ""
    var forceTools = true
    var parameters = ""
    var headers = ""

    func object(_ source: String, label: String) throws -> [String: Any] {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let data = source.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AppError.message("\(label) must be a JSON object, such as {}.") }
        return object
    }
    func validate() throws {
        if !outputTokens.isEmpty, Int(outputTokens).map({ $0 > 0 }) != true {
            throw AppError.message("Output token limit must be a positive whole number, or blank.")
        }
        if !temperature.isEmpty, Double(temperature).map({ $0.isFinite && $0 >= 0 }) != true {
            throw AppError.message("Temperature must be a non-negative number, or blank.")
        }
        if !timeout.isEmpty, Double(timeout).map({ $0.isFinite && $0 > 0 && $0 <= 3600 }) != true {
            throw AppError.message("Timeout must be between 0 and 3600 seconds, or blank.")
        }
        let parameters = try object(parameters, label: "Request parameters")
        // The host owns conversation state and tool definitions. Overrides tune the wire protocol,
        // never silently replace the task or turn on a stream this client cannot consume.
        for key in [
            "model", "messages", "input", "tools", "stream", "previous_response_id", "conversation", "background",
        ]
        where parameters[key] != nil {
            throw AppError.message("Orvlet manages ‘\(key)’. Remove it from request parameters.")
        }
        let headers = try object(headers, label: "Request headers")
        for (name, value) in headers {
            guard Self.validHeader(name), let value = value as? String,
                !value.contains("\r"), !value.contains("\n")
            else { throw AppError.message("Request headers need valid names and single-line text values.") }
            if ["host", "content-length", "content-type", "transfer-encoding", "connection"].contains(name.lowercased())
            {
                throw AppError.message("Orvlet manages the \(name) header.")
            }
        }
        if authentication == .custom {
            guard Self.validHeader(authHeader), !authPrefix.contains("\r"), !authPrefix.contains("\n"),
                !["host", "content-length", "content-type", "transfer-encoding", "connection"].contains(
                    authHeader.lowercased())
            else { throw AppError.message("Enter a valid authentication header and single-line prefix.") }
        }
    }
    static func validHeader(_ name: String) -> Bool {
        !name.isEmpty
            && name.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
                ).contains($0)
            }
    }
}

struct Endpoint: Codable, Equatable {
    var baseURL = ""
    var model = ""
    var vision = false
    var options = ModelOptions()
    init(baseURL: String = "", model: String = "", vision: Bool = false, options: ModelOptions = ModelOptions()) {
        self.baseURL = baseURL
        self.model = model
        self.vision = vision
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case baseURL, model, vision, options }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        vision = try c.decodeIfPresent(Bool.self, forKey: .vision) ?? false
        options = try c.decodeIfPresent(ModelOptions.self, forKey: .options) ?? ModelOptions()
    }
    var isConfigured: Bool {
        completionURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var completionURL: URL? {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = parts.host, !host.isEmpty, ["https", "http"].contains(parts.scheme ?? ""),
            parts.user == nil, parts.password == nil, parts.fragment == nil,
            parts.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
                || options.allowInsecureHTTP
        else { return nil }
        if !options.exactURL {
            var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // A supplied standard endpoint can also be switched to another protocol.
            for api in ModelAPI.allCases {
                if path == api.path {
                    path = ""
                    break
                }
                if path.hasSuffix("/" + api.path) {
                    path = String(path.dropLast(api.path.count + 1))
                    break
                }
            }
            parts.path = "/" + (path.isEmpty ? "" : path + "/") + options.api.path
        }
        return parts.url
    }
}
