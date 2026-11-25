import SwiftUI

struct SystemBrowserSettings: View {
    @ObservedObject var model: AppModel
    @Binding var engine: BrowserEngine
    @State private var selected: BrowserProfileImporter.Profile?
    @State private var busy = false
    @State private var notice = ""
    private var application: SystemBrowserApplication? { SystemBrowserApplication.current() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Browser").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("Browser", selection: $engine) {
                    ForEach(BrowserEngine.allCases, id: \.self) { value in
                        Text(value.title).tag(value).disabled(value == .systemBrowser && SystemBrowserApplication.sandboxed)
                    }
                }.labelsHidden().frame(width: 170)
            }
            if SystemBrowserApplication.sandboxed {
                Text("Use the Orvlet-Browser build to run your default browser inside Orvlet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if engine == .builtIn, NativeChromium.available {
                NativeExtensionSettings(host: model.nativeExtensions, model: model)
            }
            if engine == .systemBrowser {
                if let application {
                    Text("\(application.name) runs inside Orvlet with a separate, saved profile. New pages use this choice.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Menu(application.supportsExtensionImport ? "Import cookies and extensions" : "Import cookies") {
                            let profiles = BrowserProfileImporter.profiles(in: application.userData)
                            ForEach(profiles) { profile in Button(profile.name) { selected = profile } }
                            if profiles.isEmpty { Text("No browser profiles found") }
                        }.disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if !application.supportsExtensionImport {
                        Text("Chrome restricts extension imports. Use Edge or Chromium to inherit extensions.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("Manage extensions") { showExtensions() }
                } else {
                    Text("This mode supports Edge, Chrome, Brave and Chromium. Safari uses the built-in engine.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Import browser data?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let profile = selected {
                Button("Import from \(profile.name)") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let count = try await model.systemBrowserHost.importProfile(profile)
                            notice = application?.supportsExtensionImport == true
                                ? "Cookies and \(count) enabled extensions copied for the next browser start. Some sites may require login; extension settings are not copied."
                                : "Cookies copied for the next browser start. Some sites may require login."
                        } catch { notice = error.localizedDescription }
                    }
                    selected = nil
                }
                Button("Cancel", role: .cancel) { selected = nil }
            }
        } message: {
            Text(application?.supportsExtensionImport == true
                ? "Copy login cookies and enabled store extensions into Orvlet. Saved passwords, browsing history and open tabs are excluded. Your original browser stays unchanged; Orvlet's previous profile is kept as a backup."
                : "Copy login cookies into Orvlet. Saved passwords, browsing history and open tabs are excluded. Your original browser stays unchanged; Orvlet's previous profile is kept as a backup.")
        }
    }
    private func showExtensions() {
        do {
            let id = model.selectedTaskID ?? model.browser.id
            model.handoffSource = try HandoffSource(taskID: id, destination: URL(string: "chrome://extensions/")!,
                model: model, browserManager: true)
            model.selectedTaskID = id
            model.taskShelfVisible = false
            model.collapsed = false
            model.webExpanded = true
            model.onResize?(model.windowSize)
            model.onShow?()
        } catch { notice = error.localizedDescription }
    }
}
