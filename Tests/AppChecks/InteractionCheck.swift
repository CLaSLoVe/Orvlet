#if DEBUG
import AppKit
import WebKit

@MainActor
enum InteractionCheck {
    static func run(_ model: PetModel, delegate: AppDelegate) async throws -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw AgentError.message("Check failed: " + name) }
            checks.append(name)
        }
        func pause() async throws { try await Task.sleep(for:.milliseconds(450)) }
        func views(_ view: NSView) -> [WindowDragArea.DragView] {
            (view as? WindowDragArea.DragView).map { [$0] } ?? view.subviews.flatMap(views)
        }
        var compactHitTargetsValid = true
        func gesture(_ view: WindowDragArea.DragView, delta: NSPoint = .zero) {
            guard let window = view.window else { return }
            let local = view.convert(NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil)
            if window === delegate.panel && window.contentView?.hitTest(local) !== view { compactHitTargetsValid = false }
            let start = window.convertPoint(toScreen:local)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:window.convertPoint(fromScreen:point),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            view.mouseDown(with:event(.leftMouseDown,start))
            let end = NSPoint(x:start.x+delta.x,y:start.y+delta.y)
            if delta != .zero { view.mouseDragged(with:event(.leftMouseDragged,end)) }
            view.mouseUp(with:event(.leftMouseUp,end))
        }
        model.collapse(); try await pause()
        guard let media = model.microMediaTasks.first,
              let button = views(delegate.panel.contentView!).first(where:{ abs($0.bounds.width-24)<1 && $0.onClick != nil }),
              let title = views(delegate.panel.contentView!).first(where:{ abs($0.bounds.width-78)<1 && $0.onClick != nil }) else {
            throw AgentError.message("Draggable compact targets missing")
        }
        let original = delegate.panel.frame
        let wasPlaying = model.sideTasks.first(where:{$0.id == media.id})!.playing
        gesture(button,delta:NSPoint(x:-36,y:20)); try await pause()
        try check(delegate.panel.frame.origin == NSPoint(x:original.minX-36,y:original.minY+20) && model.sideTasks.first(where:{$0.id == media.id})!.playing == wasPlaying,"Dragging a playback button moves the window without toggling playback")
        gesture(title,delta:NSPoint(x:-24,y:12)); try await pause()
        try check(model.collapsed,"Dragging task text does not accidentally open details")
        gesture(button,delta:NSPoint(x:1,y:1)); try await pause()
        try check(model.sideTasks.first(where:{$0.id == media.id})!.playing != wasPlaying,"A small click wobble still activates the real playback control once")
        gesture(button); try await pause()
        gesture(title); try await pause()
        try check(!model.collapsed && !model.showingWeb && delegate.detailPanel.isVisible,"A normal click on draggable music text opens its player card")
        try check(compactHitTargetsValid,"Visible compact controls route pointer input to their drag-or-click targets")
        guard let header = views(delegate.detailPanel.contentView!).first(where:{$0.onClick == nil && abs($0.bounds.height-30)<1}) else { throw AgentError.message("Detail drag header missing") }
        let detailBefore = delegate.detailPanel.frame
        gesture(header,delta:NSPoint(x:-24,y:24)); try await pause()
        let moved = delegate.detailPanel.frame
        delegate.resize(to:model.windowSize)
        try check(moved.origin != detailBefore.origin && delegate.detailPanel.frame == moved,"Dragging the detail header keeps its new position across state updates")
        if let timer = model.sideTasks.first(where:{$0.kind == .timer}) {
            model.selectTask(timer.id,expanded:true); try await pause()
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            var card: WKWebView?
            for web in webViews(delegate.detailPanel.contentView!) {
                if (try? await web.evaluateJavaScript("typeof window.updateCard === 'function'")) as? Bool == true { card = web; break }
            }
            guard let card else { throw AgentError.message("Generated timer card missing") }
            let before = delegate.detailPanel.frame.origin
            _ = try await card.evaluateJavaScript("document.querySelector('strong').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,screenX:100,screenY:100,button:0})); document.dispatchEvent(new MouseEvent('mousemove',{screenX:130,screenY:112})); document.dispatchEvent(new MouseEvent('mouseup')); true")
            try await pause()
            try check(delegate.detailPanel.frame.origin == NSPoint(x:before.x+30,y:before.y-12),"Generated card text can drag its window through the trusted host bridge")
            let after = delegate.detailPanel.frame.origin
            _ = try await card.evaluateJavaScript("document.querySelector('button').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,screenX:100,screenY:100,button:0})); document.dispatchEvent(new MouseEvent('mousemove',{screenX:150,screenY:140})); document.dispatchEvent(new MouseEvent('mouseup')); true")
            try await pause()
            try check(delegate.detailPanel.frame.origin == after,"Generated action controls are excluded from background dragging")
        }
        model.collapse(); delegate.panel.setFrame(original,display:true)
        model.command = "A draft to preserve"
        model.selectChat(true); try await pause()
        guard let footer = views(delegate.commandPanel!.contentView!).first(where:{$0.onClick == nil && $0.bounds.width > 60 && $0.bounds.width < 250 && $0.bounds.height < 30}) else { throw AgentError.message("Command window drag area missing") }
        gesture(footer,delta:NSPoint(x:-40,y:-24))
        let movedCommand = delegate.commandPanel!.frame
        model.selectChat(false,restoreFocus:false); model.selectChat(true); try await pause()
        try check(delegate.commandPanel!.frame == movedCommand && model.command == "A draft to preserve","Command window retains a dragged position and draft on reopening")
        model.openTaskFromCommand(media.id); try await pause()
        try check(!model.commandPanelVisible && !model.collapsed && !model.showingWeb && delegate.detailPanel.isKeyWindow,"Opening a task from the composer gives focus to its details")
        let spare = BrowserController(model:model)
        model.parkedBrowsers[spare.id] = spare
        var unavailable = SideTask(kind:.web,title:"Saved page")
        unavailable.sourceURL = "http://127.0.0.1:19244/fixture?saved"; unavailable.hidden = true
        model.sideTasks.append(unavailable)
        let selection = model.selectedTaskID
        let failed = model.selectTask(unavailable.id,expanded:true)
        try check(!failed && model.lastActionError != nil && model.selectedTaskID == selection && model.sideTasks.last!.hidden,"An unavailable saved page reports why without changing selection or visibility")
        model.parkedBrowsers.removeValue(forKey:spare.id); spare.dispose(); model.sideTasks.removeAll { $0.id == unavailable.id }; model.lastActionError = nil
        if let other = model.quickMediaTasks.first(where:{$0.id != media.id}) {
            model.closeWebTask(other.id)
            try check(!model.collapsed && !model.showingWeb && model.selectedTaskID == media.id,"Closing a background page preserves the foreground player card")
        }
        model.hide(); delegate.showPet(); model.toggleTaskPresentation(media.id)
        try check(!model.collapsed && !model.showingWeb,"After hiding and showing the app, one click opens the music card again")
        model.dismissTask(media.id)
        try check(model.collapsed,"Hiding the selected task closes its details without opening another task")
        if CommandLine.arguments.contains("--keep-open") { model.selectTask(media.id); model.collapse() }
        return checks
    }
}
#endif
