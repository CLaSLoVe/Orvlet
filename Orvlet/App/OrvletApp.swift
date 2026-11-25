import AppKit
import QuartzCore
import SwiftUI

@main
enum OrvletEntry {
    static func main() {
        if CommandLine.arguments.contains("--task-code-worker") { TaskCodeWorker.main() }
        NativeChromium.prepareApplication()
        if NativeChromium.runApplication() { return }
        #if DEBUG
            if DebugHarness.startStandalonePilot() { return }
        #endif
        OrvletApp.main()
    }
}

struct OrvletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Open address…") { delegate.model.requestAddress() }.keyboardShortcut(
                        "l", modifiers: .command)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

final class ShellPanel: NSPanel {
    var onMoveInteraction: ((Bool) -> Void)?
    private var movingByGesture = false
    func moveInteraction(_ active: Bool) {
        guard movingByGesture != active else { return }
        movingByGesture = active
        onMoveInteraction?(active)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
