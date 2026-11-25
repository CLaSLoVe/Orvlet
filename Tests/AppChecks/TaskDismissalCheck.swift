#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum TaskDismissalCheck {
    static func run() async throws {
        let suite = "orvlet.dismissal.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.allowAgents = false
        model.settings.autoAdapt = false
        model.settings.appearance = .light
        let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 320, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(CalmTaskShelf(model: model)
            .background(Color(red: 0.96, green: 0.955, blue: 0.98))))
        window.contentView = host
        window.orderBack(nil)
        defer {
            model.taskClock?.invalidate()
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        }
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw AppError.message(name) }
            print("PASS " + name)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }
        func targets(_ view: NSView) -> [TaskDragHandle.HandleView] {
            (view as? TaskDragHandle.HandleView).map { [$0] } ?? view.subviews.flatMap(targets)
        }
        func title(_ id: UUID) throws -> TaskDragHandle.HandleView {
            guard let target = targets(host).first(where: { $0.identifier?.rawValue == id.uuidString && $0.bounds.width > 50 })
            else { throw AppError.message("Missing rendered shelf title: " + id.uuidString) }
            return target
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func click(_ point: NSPoint) {
            window.sendEvent(event(.leftMouseDown, point))
            window.sendEvent(event(.leftMouseUp, point))
        }
        func button(_ id: UUID, close: Bool = false) throws {
            let target = try title(id)
            let rect = target.convert(target.bounds, to: nil)
            // The actual adjacent editing buttons, located from the rendered row.
            click(NSPoint(x: rect.maxX + 6 + 13 + (close ? 32 : 0), y: rect.midY))
        }
        func drag(_ id: UUID, outside: Bool, cancel: Bool = false) throws {
            let target = try title(id)
            let rect = target.convert(target.bounds, to: nil)
            let start = NSPoint(x: rect.midX, y: rect.midY)
            try check(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === target, "Shelf title receives pointer input")
            window.sendEvent(event(.leftMouseDown, start))
            let end = outside ? NSPoint(x: window.frame.width + 80, y: start.y) : NSPoint(x: start.x, y: start.y - 46)
            window.sendEvent(event(.leftMouseDragged, end))
            if cancel {
                window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: end, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            }
            window.sendEvent(event(.leftMouseUp, end))
        }
        let tea = try model.startTimer(seconds: 300, title: "Tea")
        let bread = try model.startTimer(seconds: 540, title: "Bread")
        let artifact = model.work.retain(title: "Parcel", values: ["delivery": "In transit"],
            definition: WorkDefinition(), design: WorkDesign(), goalID: nil)
        let parcel = try model.presentWork([artifact], layout: .single, title: "Parcel")[0]
        let deadline = model.sideTasks.first { $0.id == tea }!.deadline
        model.activeRequest = nil
        model.taskShelfVisible = true
        model.taskListEditing = true
        model.taskOrder = [tea, bread, parcel]
        window.setContentSize(model.shellContentSize!)
        try await settle()
        try button(parcel)
        try await settle()
        model.projectWorkResult(artifact)
        try check(model.orderedTasks.count == 3 && model.visibleTasks.count == 2
            && model.work.view(parcel)?.hidden == true, "Rendered Hide keeps the saved result and shelf entry")
        try button(parcel)
        try await settle()
        model.projectWorkResult(artifact)
        model.persistSideTasks()
        try check(model.visibleTasks.count == 3 && model.work.view(parcel)?.hidden == false,
                  "Rendered Show restores the same card and survives result projection")
        try button(parcel)
        try await settle()
        let hiddenTitle = try title(parcel)
        click(hiddenTitle.convert(NSPoint(x: hiddenTitle.bounds.midX, y: hiddenTitle.bounds.midY), to: nil))
        try await Task.sleep(for: .seconds(1))
        model.projectWorkResult(artifact)
        try check(model.visibleTasks.contains { $0.id == parcel } && model.work.view(parcel)?.hidden == false,
                  "Opening a hidden row also persists its visible state")
        model.taskShelfVisible = true
        try await settle()
        try drag(tea, outside: false)
        try await settle()
        try check(model.orderedTasks.map(\.id) == [bread, tea, parcel], "Dragging a title inside Tasks reorders without closing")
        try drag(tea, outside: true, cancel: true)
        try await settle()
        try check(model.orderedTasks.count == 3 && model.draggingTaskID == nil, "Escape cancels an outside drag")
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-task-dismissal-" + UUID().uuidString + ".png")
        try await SideScreenCheck.snapshot(window, path: snapshot.path)
        print("SHELF_IMAGE " + (try Data(contentsOf: snapshot)).base64EncodedString())
        try button(parcel, close: true)
        try await settle()
        let result = model.work.artifact(artifact)!
        _ = model.work.update(artifact, expecting: result.revision) { $0.values["delivery"] = "Delivered" }
        model.projectWorkResult(artifact)
        try check(model.orderedTasks.count == 2 && !model.sideTasks.contains { $0.id == parcel }
            && model.work.artifact(artifact)?.values["delivery"] == "Delivered",
            "Rendered Close removes a result view permanently while retaining updated results")
        try drag(tea, outside: true)
        try await settle()
        model.tickTasks()
        model.persistSideTasks()
        try check(model.orderedTasks.map(\.id) == [bread] && model.overflowTaskCount == 0
            && model.sideTasks.first { $0.id == tea }?.deadline == deadline,
            "Dragging a native title outside removes its shelf entry without recreating it on a timer tick")
        try button(bread)
        try await settle()
        try check(model.visibleTasks.isEmpty && model.orderedTasks.count == 1, "A native card can be hidden")
        try button(bread)
        try await settle()
        try check(model.visibleTasks.map(\.id) == [bread], "A native card can be shown with the same ID")
        defaults.set(try model.shelfArchive.encoded(model.sideTasks), forKey: "sideTasks.v1")
        let restored = AppModel(defaults: defaults)
        restored.isLiveTest = true
        restored.loadSideTasks()
        defer { restored.taskClock?.invalidate() }
        try check(restored.orderedTasks.map(\.id) == [bread] && restored.visibleTasks.map(\.id) == [bread]
            && restored.work.artifact(artifact)?.values["delivery"] == "Delivered",
            "Reload preserves closed, hidden and visible states separately from results")
        model.setCompactLayout(.vertical)
        host.rootView = AnyView(CalmStrip(model: model).frame(width: model.compactSize.width, height: model.compactSize.height))
        try await settle()
        func compactTargets(_ view: NSView) -> [WindowDragArea.DragView] {
            (view as? WindowDragArea.DragView).map { [$0] } ?? view.subviews.flatMap(compactTargets)
        }
        guard let compact = compactTargets(host).first(where: { $0.identifier?.rawValue == bread.uuidString && $0.bounds.width > 50 })
        else { throw AppError.message("Missing compact card drag target") }
        let start = compact.convert(NSPoint(x: compact.bounds.midX, y: compact.bounds.midY), to: nil)
        try check(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === compact, "Compact card receives pointer input")
        window.sendEvent(event(.leftMouseDown, start))
        let outside = NSPoint(x: window.frame.width + 80, y: start.y)
        window.sendEvent(event(.leftMouseDragged, outside))
        window.sendEvent(event(.leftMouseUp, outside))
        try await settle()
        model.persistSideTasks()
        try check(model.orderedTasks.isEmpty && model.visibleTasks.isEmpty && model.overflowTaskCount == 0,
                  "Dragging the compact card outside removes it from both the capsule and Tasks")
        print(JSONText.encode(["ok": true, "remaining": model.orderedTasks.map { ["id": $0.id.uuidString, "title": $0.title] }]))
    }
}
#endif
