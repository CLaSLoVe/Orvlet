#if DEBUG
import AppKit
import WebKit

@MainActor
enum ListeningCheck {
    static func run(_ model: PetModel, delegate: AppDelegate) async {
        model.isLiveTest = true; model.persistHistory = false; model.settings.autoAdapt = false
        model.settings.main = Endpoint(); model.settings.reduceMotion = true
        var checks: [String] = []
        func check(_ ok: Bool,_ name: String) throws { guard ok else { throw AgentError.message(name) }; checks.append(name) }
        func pause() async throws { try await Task.sleep(for:.milliseconds(450)) }
        do {
            let source = model.browser
            let page = try await source.action(["action":"navigate","url":"http://127.0.0.1:19244/fixture?listening"])
            _ = try await source.action(["action":"media","operation":"play"])
            var plan = SurfacePlan(components:[],width:300,height:160,title:"Music")
            plan.markup = CardMarkup(html:"<h2 data-bind='title'></h2><button data-action='next'>Next</button>",compactHTML:"",css:"h2{font-size:16px}",height:140)
            plan.actions = [BoundCardAction(id:"next",binding:PageBinding(action:"click",role:"button",name:"Next item"))]
            model.install(try plan.validated(observation:page)); model.hasCustomSurface = true
            model.upsertWebTask(model.surface,activate:true)
            try check(model.selectedSideTask?.isMediaTask == true,"Generated DOM-click controls do not demote primary media to a webpage")
            model.beginBackgroundListening(); model.upsertWebTask(model.surface)
            model.collapse(); model.toggleTaskPresentation(source.id); try await pause()
            try check(!model.collapsed && !model.showingWeb && model.selectedSideTask?.listening == true,"Opening a listening task displays the player card rather than its webpage")
            var guarded = plan
            guarded.actions?.append(BoundCardAction(id:"pause",binding:PageBinding(action:"media",operation:"pause"),revealSource:true))
            model.install(try guarded.validated(observation:try await source.observe())); model.upsertWebTask(model.surface)
            model.cardAction(source.id,action:"pause",value:nil); try await pause()
            let paused = try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool == true
            try check(!model.showingWeb && paused,"A generated media action cannot reveal the source even if its layout requests it")
            _ = try await source.action(["action":"media","operation":"play"])
            model.collapse(); model.reveal(preview:true)
            try check(!model.showingWeb,"Hover preview cannot replace a listening card with the source webpage")
            model.cardAction(source.id,action:"source",value:nil); try await pause()
            try check(model.showingWeb && model.browser === source,"Explicit source action still reveals the same live webpage")
            model.collapse()
            let webIdentity = source.webView
            _ = try await source.webView.evaluateJavaScript("window.savedAudio=document.querySelector('audio');window.savedAudio.remove();history.pushState({},'', '/fixture?next-track')")
            source.updateState(try await source.observe())
            try check(model.selectedSideTask?.isMediaTask == true && model.selectedSideTask?.hasMedia == false && model.selectedSideTask?.status == "Loading…","Player replacement and playlist URL changes retain the listening card with loading status")
            try check(model.collapsed && !model.showingWeb && source.webView === webIdentity,"Transient media loss never expands or replaces the source context")
            let saved = try JSONDecoder().decode(SideTask.self,from:JSONEncoder().encode(model.selectedSideTask!))
            try check(saved.listening == true && saved.isMediaTask,"Listening intent persists even when saved between tracks")
            _ = try await source.webView.evaluateJavaScript("document.body.append(window.savedAudio)")
            _ = try await source.action(["action":"media","operation":"play"])
            source.updateState(try await source.observe())
            model.controlMedia(source.id,operation:"pause"); try await pause()
            try check(try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool == true,"Native pause remains available after the player is replaced")
            model.controlMedia(source.id,operation:"play"); try await pause()
            try model.prepareBrowserForNewTask()
            _ = try await model.browser.action(["action":"navigate","url":"http://127.0.0.1:19244/live-reading"])
            model.upsertWebTask(activate:true)
            try check(model.sideTasks.first(where:{$0.id == model.browser.id})?.isMediaTask == false,"A new clock page with incidental audio does not inherit the music role")
            _ = try await source.webView.evaluateJavaScript("document.querySelector('audio').style.display='none'")
            source.updateState(try await source.observe())
            try check(model.quickMediaTasks.contains(where:{$0.id == source.id}),"A parked listening task retains controls when its underlying media becomes visually hidden")
            model.selectTask(source.id,expanded:true); try await pause()
            try check(!model.showingWeb && source.webView === webIdentity,"Returning from another task opens the retained music card without reloading")
            model.controlMedia(source.id,operation:"pause"); try await pause()
            try check(try await source.webView.evaluateJavaScript("document.querySelector('audio').paused") as? Bool == true,"Background music controls still target the owning player")
            var watching = saved; watching.listening = false; watching.prefersSource = true
            try check(watching.opensSourceByDefault,"An explicitly watching task can still prefer the video webpage")
            var changed = saved
            changed.updateMediaRole(primary:false,url:"https://example.org/clock")
            changed.hasMedia = true
            try check(!changed.isMediaTask && changed.listening == false && changed.opensSourceByDefault,"An unrelated origin does not inherit the listening role")
            model.selectTask(model.browser.id,expanded:true)
            try check(model.showingWeb,"Non-media tasks retain their direct source interaction")
            try JSONSerialization.data(withJSONObject:["ok":true,"checks":checks,"scope":"Local real WebKit playback and DOM/URL transition fixtures; no live YouTube ad claim"],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-listening-checks.json"))
            exit(0)
        } catch {
            try? JSONSerialization.data(withJSONObject:["ok":false,"checks":checks,"error":error.localizedDescription],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-listening-checks.json")); exit(1)
        }
    }
}
#endif
