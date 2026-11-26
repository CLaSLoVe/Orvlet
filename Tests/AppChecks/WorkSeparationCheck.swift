#if DEBUG
import AppKit
import Foundation
import WebKit

@MainActor
enum WorkSeparationCheck {
    static func timerViews(_ model: AppModel) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            try StateMachineCheck.require(condition, message, &checks)
        }
        defer { model.taskClock?.invalidate() }
        let timer = try model.startTimer(seconds:300,title:"Tea")
        let timer2 = try model.startTimer(seconds:300,title:"Bread")
        let resource = model.work.view(timer)!.selected
        let resource2 = model.work.view(timer2)!.selected
        let deadline = model.work.artifact(resource)!.native!.deadline
        let alias = try model.presentWork([resource],layout:.single,title:"Tea",destination:UUID())[0]
        model.closeTask(timer)
        try require(resource != resource2 && model.work.artifact(resource)?.native?.deadline == deadline
            && model.sideTasks.contains(where:{ $0.id == alias && !$0.hidden }), "Same-duration native resources stay distinct and closing a view keeps the timer running")
        await model.performWorkOperation(resource,action:"stop",fields:[:])?.value
        try require(model.work.artifact(resource)?.native?.finished == true
            && model.work.artifact(resource2)?.native?.deadline != nil, "An explicit resource stop leaves the other timer running")
        model.timerAction(timer, action: "restart")
        if let index = model.sideTasks.firstIndex(where: { $0.id == timer }) {
            model.sideTasks[index].deadline = .now.addingTimeInterval(-1)
        }
        model.tickTasks()
        guard let alarm = model.reminders.first(where: { $0.owner == timer }) else {
            throw AppError.message("The remaining Timer view lost the original countdown’s alarm")
        }
        try require(model.timerAlarmView(for: timer) == alias && model.timerEntries.contains { $0.pendingTimerReminderID == alarm.id },
                    "A countdown with a surviving view delivers one alarm on its original resource")
        model.acknowledgeTimerFromTool(timer)
        return checks
    }

    static func run(_ model: AppModel) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AppError.message(message) }
            print("PASS " + message)
        }
        model.sideTasks = []
        var reads = 0
        model.apiData = APIDataService(code:model.taskCode,fetch:{ url in
            reads += 1
            return ["name":url.hasSuffix("north") ? "North" : "South", "count":url.hasSuffix("north") ? 24 : 40]
        })
        var ids: [UUID] = []
        for name in ["north","south"] {
            let spec = APIDataSpec(url:"https://example.org/inventory/" + name,
                fields:[.init(key:"name",label:"Depot",pointer:"/name"),.init(key:"count",label:"Items",pointer:"/count")],
                inputs:["group":"2"], controls:[.init(key:"group",label:"Group size",kind:"number")],
                calculation:"return {state:{groups:String(Number(state.count)/Number(input.group))}};",
                outputs:[.init(key:"groups",label:"Groups")],
                card:.init(kind:.reading,primaryKey:"groups",subject:name,displayNameKey:"name"))
            let values = try await model.apiData.read(spec)
            ids.append(model.retainWorkResult(title:name.capitalized,values:values,spec:spec))
        }
        try require(model.sideTasks.isEmpty && model.work.artifact(ids[0])?.values["groups"] == "12", "Results exist and are executable before any card")
        let first = model.work.artifact(ids[0])!
        let operation = try model.workSurface(first).actions.first { $0.operation == "update" }!.id
        let job = model.performWorkOperation(ids[0],action:operation,fields:["group":"4"])!
        await job.value
        try require(model.sideTasks.isEmpty && model.work.artifact(ids[0])?.values["groups"] == "6" && reads == 2, "Operation without a card reuses verified source data")
        let firstGoal = RequestRun(model:model)
        model.work.begin(goalID:firstGoal.goalID,runID:firstGoal.runID,request:"Show saved inventory")
        for id in ids { firstGoal.retainResult(id, needsView:true) }
        let published = try RequestRun.$current.withValue(firstGoal) {
            try firstGoal.agent.presentResults(["results":[ids[0].uuidString],"layout":"together","title":"Inventory"])
        }
        let one = (published["views"] as! [String]).compactMap(UUID.init(uuidString:))
        try require(!firstGoal.awaitingPresentation && model.work.artifact(ids[1]) != nil,
            "Goal delivery does not require a separate view for every acquired intermediate result")
        try require(model.work.view(one[0])?.layout == .single && model.sideTasks.first?.taskSurface?.hasEditableOperation == true,
            "A single result keeps its operations when a joint layout is requested")
        let separate = try model.presentWork(ids,layout:.single,title:"Inventory")
        let combined = try model.presentWork(ids,layout:.together,title:"Inventory")
        let selected = try model.presentWork(ids,layout:.select,title:"Inventory")
        try require(model.visibleTasks.count == 4 && reads == 2, "Several views share two results without repeating work")
        let window = NSWindow(contentRect:NSRect(x:-16000,y:-16000,width:300,height:320),styleMask:.borderless,backing:.buffered,defer:false)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        model.fitCardSurface(selected[0],height:280)
        try model.projectWorkView(selected[0])
        let selectionTask = model.sideTasks.first { $0.id == selected[0] }!
        let web = try await SimpleTaskPilot.expanded(model,task:selectionTask,window:window)
        let selectorCount = try await web.evaluateJavaScript("document.querySelectorAll('select[data-field=workSelection]').length") as? Int
        try require(selectorCount == 1 && model.work.view(selected[0])?.markup == nil,
            "Height measurement never freezes result markup or duplicates selection controls")
        _ = try await web.evaluateJavaScript("(()=>{let e=document.querySelector('select[data-field=workSelection]');e.value=" + JSONText.encode(ids[1].uuidString) + ";e.dispatchEvent(new Event('change',{bubbles:true}));return e.value})()")
        for _ in 0..<40 {
            if model.work.view(selected[0])?.selected == ids[1] { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        try require(model.work.view(selected[0])?.selected == ids[1] && reads == 2, "Actual select event changes only the view's selected result")
        let current = model.work.artifact(ids[0])!
        var edited = model.work.view(separate[0])!
        edited.markup = try model.surfaceForView(edited).markup
        edited.markup?.css += "\n.calm-value{font-weight:600}"
        try model.work.putView(edited)
        try model.projectWorkView(edited.id)
        try require(model.work.artifact(ids[0])?.revision == current.revision, "View edits do not change result or execution revisions")
        model.closeTask(separate[0])
        try require(model.work.artifact(ids[0]) != nil && model.visibleTasks.count == 3, "Closing one view retains shared work")
        let next = model.performWorkOperation(ids[0],action:operation,fields:["group":"6"])!
        await next.value
        try require(model.sideTasks.first { $0.id == combined[0] }?.state["reading0"] == "4", "A later operation updates the surviving joint view")
        try require(!model.work.update(ids[0],expecting:current.revision,{ $0.values["groups"] = "wrong" }), "Stale execution cannot overwrite a newer result")
        var broken = model.work.view(combined[0])!
        broken.layout = .single
        broken.markup = CardMarkup(html:"<strong data-bind='missing'></strong>",compactHTML:"<strong data-bind='missing'></strong>",css:"",height:120)
        try model.work.putView(broken)
        model.projectWorkResult(ids[0])
        try require(model.work.artifact(ids[0])?.values["groups"] == "4", "A rejected view leaves the verified result intact")
        await model.performWorkOperation(ids[0],action:operation,fields:["group":"8"])?.value
        try require(model.work.artifact(ids[0])?.values["groups"] == "3", "Broken markup cannot disable a registered result operation")
        broken.layout = .together
        broken.markup = nil
        try model.work.putView(broken)
        try model.projectWorkView(broken.id)
        await model.performWorkOperation(ids[0],action:operation,fields:["group":"6"])?.value
        for check in try await timerViews(model) { print("PASS " + check) }
        let sourceID = UUID()
        let edit = RequestRun(model:model)
        model.sideTasks.append(SideTask(id:sourceID,kind:.web,title:"Working page"))
        model.persistSideTasks()
        model.work.begin(goalID:edit.goalID,runID:edit.runID,request:"Edit the retained result using a page")
        edit.context = TaskRequestContext(input:"Edit the retained result using a page",receivedAt:Date(),startPolicy:.interfaceFirst,
            owner:.web(sourceID),browserResourceID:sourceID)
        edit.context?.submittedTaskID = separate[0]
        try RequestRun.$current.withValue(edit) {
            _ = try edit.agent.presentResults(["results":[ids[1].uuidString],"layout":"separate","title":"Updated result"])
        }
        try require(model.work.view(separate[0])?.selected == ids[1]
            && model.sideTasks.first(where:{ $0.id == sourceID })?.kind == .web
            && model.sideTasks.first(where:{ $0.id == sourceID })?.hidden == true
            && model.work.view(sourceID).flatMap { model.work.artifact($0.selected)?.native?.id } == sourceID,
            "Borrowing a page preserves the original view destination and the native resource")
        try require(model.work.snapshot.goals[edit.goalID]?.results.contains(ids[1]) == true,
            "A later goal can reference an existing result without becoming its view")
        let restored = WorkRepository(defaults:model.preferences)
        try require(restored.artifact(ids[0])?.values["groups"] == "4" && restored.view(selected[0])?.selected == ids[1], "Results and view references restore independently")
        print(JSONText.encode(["results":ids.map(\.uuidString),"views":model.visibleTasks.map { $0.id.uuidString },"reads":reads,"ok":true]))
        model.dataRefreshTimer?.invalidate()
    }
}
#endif
