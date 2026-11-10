import AppKit
import QuartzCore
import SwiftUI

@main
enum OrvletEntry {
    static func main() {
        if CommandLine.arguments.contains("--task-code-worker") { TaskCodeWorker.main() }
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
