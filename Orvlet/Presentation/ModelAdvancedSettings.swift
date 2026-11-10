import SwiftUI

struct ModelAdvancedSettings: View {
    @Binding var endpoint: Endpoint
    @State private var expanded = false
    @State private var customExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("API format", selection: $endpoint.options.api) {
                ForEach(ModelAPI.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityLabel("API format")
            DisclosureGroup("Advanced settings", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Use URL exactly as entered", isOn: $endpoint.options.exactURL)
                        .toggleStyle(.switch).controlSize(.small)
                    Text(
                        endpoint.options.exactURL
                            ? "Send requests to this exact address, including its query parameters."
                            : "Adds /\(endpoint.options.api.path) to the base URL when needed. Query parameters are preserved."
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    if endpoint.baseURL.lowercased().hasPrefix("http://"),
                        !["localhost", "127.0.0.1", "::1", "[::1]"].contains(
                            URLComponents(string: endpoint.baseURL)?.host ?? "")
                    {
                        Toggle("Allow HTTP for this connection", isOn: $endpoint.options.allowInsecureHTTP)
                            .toggleStyle(.switch).controlSize(.small)
                        Text("For a trusted local network. HTTP sends the key and task content without encryption.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Picker("Authentication", selection: $endpoint.options.authentication) {
                        ForEach(ModelAuthentication.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if endpoint.options.authentication == .custom {
                        field("Key header", placeholder: "api-key", value: $endpoint.options.authHeader)
                        field(
                            "Key prefix", placeholder: "Optional, e.g. Bearer followed by a space",
                            value: $endpoint.options.authPrefix)
                    }
                    if endpoint.options.api != .messages {
                        Picker("Reasoning", selection: $endpoint.options.reasoning) {
                            ForEach(ModelReasoning.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text(
                            endpoint.options.reasoning == .automatic
                                ? "Keeps Orvlet’s existing optimizations where available; otherwise uses the provider default."
                                : "Use an effort supported by your model. Provider default omits Orvlet’s reasoning parameters."
                        )
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field(
                            "Output token limit",
                            placeholder: endpoint.options.api == .messages ? "8192" : "Provider default",
                            value: $endpoint.options.outputTokens)
                        field("Temperature", placeholder: "Provider default", value: $endpoint.options.temperature)
                    }
                    if endpoint.options.api == .chatCompletions && !endpoint.options.outputTokens.isEmpty {
                        Picker("Token limit field", selection: $endpoint.options.tokenParameter) {
                            Text("max_completion_tokens").tag("max_completion_tokens")
                            Text("max_tokens").tag("max_tokens")
                        }
                    }
                    field("Request timeout (seconds)", placeholder: "Automatic", value: $endpoint.options.timeout)
                    Toggle("Force required tool calls", isOn: $endpoint.options.forceTools)
                        .toggleStyle(.switch).controlSize(.small)
                    Text(
                        "Turn off if your provider only supports automatic tool choice. Orvlet still validates the returned tool calls."
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    DisclosureGroup("Custom parameters & headers", isExpanded: $customExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            jsonField("Request parameters (JSON)", value: $endpoint.options.parameters)
                            Text(
                                "Overrides the options above. Use null to omit a parameter. Conversation, model and tool definitions stay managed by Orvlet."
                            )
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            jsonField("Request headers (JSON)", value: $endpoint.options.headers)
                            Text(
                                "Use ${API_KEY} to insert the saved key; keep secrets in the API Key field. Example: {\"api-key\": \"${API_KEY}\"}."
                            )
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }.padding(.top, 10)
            }
        }.font(.system(size: 12))
    }
    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: value).textFieldStyle(.plain).padding(10)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func jsonField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: value).font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden).padding(7).frame(height: 96)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel(title)
        }
    }
}
