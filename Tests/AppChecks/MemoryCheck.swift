#if DEBUG
import AppKit

@MainActor
enum MemoryCheck {
    static func start() async {
        let focus = BackgroundFocusCheck()
        let groups: [(String, () async throws -> [String])] = [
            ("Task memory", TaskMemoryCheck.run),
            ("Site memory", { try await SiteMemoryCheck.run() }),
            ("Settings", MemorySettingsCheck.run),
        ]
        var checks: [String] = []
        var errors: [String] = []
        for (name, run) in groups {
            do { checks += try await run() }
            catch { errors.append(name + ": " + error.localizedDescription) }
        }
        if focus.tookFocus || NSApp.windows.contains(where: { $0.isVisible }) {
            errors.append("A memory check activated Orvlet or left a visible window.")
        }
        let report: [String: Any] = ["ok": errors.isEmpty, "checks": checks, "errors": errors]
        do {
            try JSONSerialization.data(withJSONObject: report).write(
                to: URL(fileURLWithPath: "/tmp/orvlet-memory-checks.json"), options: .atomic)
        } catch { exit(1) }
        exit(errors.isEmpty ? 0 : 1)
    }
}
#endif
