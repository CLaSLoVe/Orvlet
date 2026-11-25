import SwiftUI

struct NativeExtensionSettings: View {
    @ObservedObject var host: NativeExtensions
    let model: AppModel
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remember website logins", isOn: Binding(get: { host.keepLogins }, set: { value in
                perform { try host.setKeepLogins(value) }
            })).help("Keep site data across launches using macOS Keychain. Off uses a guest session.")
            Divider()
            HStack {
                Text("Extensions").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Install extension…") { choose() }.disabled(host.pending != nil)
            }
            if host.entries.isEmpty {
                Text("For ad blocking, install a content blocker of your choice.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(host.entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(entry.version).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Toggle("Enable \(entry.name)", isOn: Binding(get: { entry.enabled }, set: { value in
                        perform { try host.setEnabled(entry.id, value) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Menu {
                        if let _ = try? host.pageURL(entry) {
                            Button("Options") { perform { try open(entry) } }.disabled(!entry.enabled || host.restartRequired)
                        }
                        Button("Remove", role: .destructive) { perform { try host.remove(entry.id) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("\(entry.name) options")
                }
            }
            if host.restartRequired {
                Text("Restart Orvlet to apply browser changes.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let issue = host.issue { Text(issue).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $reviewing, onDismiss: { host.cancel() }) {
            if let pending = host.pending {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pending.entry.name).font(.system(size: 18, weight: .medium))
                    Text("This extension requests access to:").font(.system(size: 12))
                    ScrollView {
                        Text(pending.permissions.isEmpty ? "No additional permissions" : pending.permissions)
                            .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                    HStack {
                        Spacer()
                        Button("Cancel") { host.cancel(); reviewing = false }
                        Button("Install") { perform { try host.install(); reviewing = false } }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 380)
            }
        }
    }
    private func perform(_ work: () throws -> Void) {
        host.issue = nil
        do { try work() } catch { host.issue = error.localizedDescription }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked Chrome extension folder containing manifest.json."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            perform { try host.prepare(url); reviewing = true }
        }
    }
    private func open(_ entry: NativeExtensions.Entry) throws {
        guard let url = try host.pageURL(entry) else { throw AppError.message("This extension has no options page.") }
        let id = model.selectedTaskID ?? model.browser.id
        model.handoffSource = try HandoffSource(taskID: id, destination: url, model: model, browserManager: true)
        model.selectedTaskID = id
        model.taskShelfVisible = false
        model.collapsed = false
        model.webExpanded = true
        model.onResize?(model.windowSize)
        model.onShow?()
    }
}
