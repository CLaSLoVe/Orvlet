import SwiftUI
import UniformTypeIdentifiers
import WebKit

@available(macOS 15.4, *)
struct BrowserExtensionSettings: View {
    @ObservedObject var host: BrowserExtensions
    let web: WKWebView?
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Browser extensions").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Import…") { chooseFolder() }
                    .disabled(host.busy || host.pending != nil)
                    .accessibilityIdentifier("import-browser-extension")
            }
            if host.entries.isEmpty {
                Text(
                    "Import a Chrome or Safari web extension ZIP or unpacked folder. Compatibility depends on its APIs."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(host.entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(entry.version) · \(entry.digest.prefix(8))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Toggle(
                        "Enable \(entry.name)",
                        isOn: Binding(
                            get: { host.contexts[entry.id] != nil },
                            set: { enabled in run { try await host.setEnabled(entry.id, enabled) } }
                        )
                    ).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Menu {
                        Button("Open extension") { host.perform(entry.id, on: web) }
                            .disabled(host.contexts[entry.id] == nil)
                        Button("Remove", role: .destructive) { run { try await host.remove(entry.id) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("\(entry.name) options")
                }.disabled(host.busy || host.pending != nil)
            }
            if !host.entries.isEmpty {
                Text("Reload open pages after changing extensions.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let issue = host.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $reviewing, onDismiss: { host.cancelImport() }) {
            if let pending = host.pending {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pending.entry.name).font(.system(size: 18, weight: .medium))
                    Text("This extension requests access to:").font(.system(size: 12))
                    ScrollView {
                        Text(pending.permissions.isEmpty ? "No additional permissions" : pending.permissions)
                            .font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            host.cancelImport()
                            reviewing = false
                        }
                        Button("Install") {
                            do {
                                try host.approveImport()
                                reviewing = false
                            } catch {
                                host.issue = error.localizedDescription
                                host.cancelImport()
                                reviewing = false
                            }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 380)
            }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            host.issue = nil
            do { try await operation() } catch { host.issue = error.localizedDescription }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an extension ZIP or the folder containing manifest.json."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            run {
                try await host.prepareImport(url)
                reviewing = true
            }
        }
    }
}

@available(macOS 15.4, *)
struct BrowserExtensionMenu: View {
    @ObservedObject var host: BrowserExtensions
    let web: WKWebView
    var body: some View {
        if !host.entries.isEmpty {
            Menu {
                ForEach(host.entries) { entry in
                    Button("\(entry.name) · \(entry.version) · \(entry.digest.prefix(8))") {
                        host.perform(entry.id, on: web)
                    }
                    .disabled(host.contexts[entry.id] == nil || host.busy)
                }
            } label: {
                Image(systemName: "puzzlepiece.extension").frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Extensions")
        }
    }
}
