#if DEBUG
    import AppKit
    import SwiftUI

    @MainActor
    enum ModelProfileCheck {
        static func run() throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            let legacy = Data(
                #"{"main":{"baseURL":"https://provider-a.example/v1","model":"model-a","vision":true},"fast":{"baseURL":"https://api.typesafe.ai/v1","model":"jev-latest","vision":false},"useFast":true}"#
                    .utf8)
            var settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
            try check(
                settings.profiles.count == 1 && settings.mainConnection.keyAccount == "main" && settings.main.vision,
                "Migration preserves the original model and credential reference without reading or copying credentials"
            )
            let oldID = settings.activeProfileID
            let original = settings.mainConnection
            settings.addProfile()
            settings.main = Endpoint(baseURL: "https://provider-b.example/v1", model: "model-b")
            settings.storeActiveProfile()
            let secondID = settings.activeProfileID
            let secondAccount = settings.mainConnection.keyAccount
            try check(
                secondAccount != original.keyAccount && settings.profiles.count == 2,
                "New profiles have separate credentials")
            _ = settings.selectProfile(oldID)
            try check(
                settings.main == original.endpoint && settings.mainConnection.keyAccount == original.keyAccount,
                "Switching back restores endpoint, vision and credential identity together")
            try check(
                settings.useFast && settings.fast.model == "jev-latest" && settings.fastKeyAccount == "fast",
                "Main-model switching preserves shared Jev settings and its existing key")
            _ = settings.selectProfile(secondID)
            settings.main.model = "model-b-updated"
            settings.storeActiveProfile()
            try check(
                settings.mainConnection.keyAccount == secondAccount,
                "Changing the model at the same provider keeps that profile's saved key")
            settings.main.baseURL = "https://provider-c.example/v1"
            settings.storeActiveProfile()
            try check(
                settings.mainConnection.keyAccount != secondAccount,
                "Changing provider never sends the previous provider's credential to a new host")
            try check(
                original.endpoint.model == "model-a" && original.keyAccount == "main",
                "In-flight model connections stay immutable while profiles change")
            let data = try JSONEncoder().encode(settings)
            var restored = try JSONDecoder().decode(AppSettings.self, from: data)
            try check(
                restored.activeProfileID == secondID && restored.main == settings.main && restored.useFast,
                "Profiles, selection and Jev enablement survive relaunch")
            try check(
                !String(decoding: data, as: UTF8.self).contains("apiKey"),
                "Profile preferences contain credential references, never key values")
            let before = restored.activeProfileID
            try check(
                !restored.selectProfile("missing") && restored.activeProfileID == before,
                "An unknown profile cannot silently replace the active model")
            try check(
                restored.removeProfile(secondID) && restored.activeProfileID == oldID
                    && restored.main.model == "model-a",
                "Removing the active profile selects the remaining profile coherently")
            try check(!restored.removeProfile(oldID), "The final profile is retained")
            restored.useFast = false
            restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored))
            try check(restored.useFast, "Legacy disabled Jev migrates to the required configuration")
            var applied = settings
            applied.allowAgents = true
            var draft = settings
            draft.allowAgents = false
            draft.theme = .mint
            draft.main.model = "Unfinished model edit"
            applied.applyPreferences(from: draft)
            try check(
                applied.allowAgents && applied.main == settings.main && applied.theme == .mint,
                "Instant preferences preserve access choices and do not apply unfinished model edits")
            applied.appearance = .light
            draft.appearance = .dark
            applied.applyModels(from: draft)
            try check(
                applied.allowAgents && applied.appearance == .light && applied.main.model == "Unfinished model edit",
                "Saving model changes cannot overwrite access or appearance with a stale draft")
            return checks
        }

        static var previewWindow: NSWindow?
        static func preview(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings = AppSettings()
            model.settings.autoAdapt = false
            model.settings.appearance = .light
            model.settings.reduceMotion = true
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244/required-tool", model: "Primary model")
            model.settings.ensureProfiles()
            model.settings.profiles[0].name = "Everyday"
            let first = model.settings.activeProfileID
            model.settings.addProfile()
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244/required-tool", model: "Research model")
            model.settings.storeActiveProfile()
            model.settings.profiles[1].name = "Research"
            _ = model.settings.selectProfile(first)
            model.settings.useFast = true
            model.settings.fast = Endpoint(baseURL: "http://127.0.0.1:19244/v1", model: "jev-fixture")
            let window = NSWindow(
                contentRect: NSRect(x: 160, y: 160, width: 520, height: 710), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Orvlet Models Preview"
            window.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: 2))
            previewWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            do {
                try await Task.sleep(for: .milliseconds(600))
                try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-models-light.png")
                if !CommandLine.arguments.contains("--keep-open") { exit(0) }
            } catch {
                fputs("Settings preview failed\n", stderr)
                exit(1)
            }
        }
    }
#endif
