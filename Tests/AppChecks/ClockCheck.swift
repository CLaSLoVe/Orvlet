#if DEBUG
import AppKit
import WebKit

@MainActor
enum ClockCheck {
    static func run(_ model: PetModel, delegate: AppDelegate) async {
        model.isLiveTest = true; model.persistHistory = false; model.settings.autoAdapt = false
        model.settings.appearance = .light; model.latestIntent = "Use this page as a live clock. Generate a useful compact view of its current time and location, with live readings. It is not a music task."
        var stage = "Loading public page"
        do {
            let page = try await model.browser.action(["action":"navigate","url":"https://time.is/"])
            try JSONSerialization.data(withJSONObject:page,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-clock-observation.json"))
            if CommandLine.arguments.contains("--observe-only") {
                let readings = page["readables"] as? [[String:Any]] ?? []
                guard let selector = readings.first(where:{$0["role"] as? String == "time"})?["selector"] as? String else { throw AgentError.message("No observed time element") }
                try await model.browser.bindReadings([CardReading(key:"clock",selector:selector)])
                let first = (try await model.browser.observe())["readings"] as? [String:String] ?? [:]
                try await Task.sleep(for:.seconds(2))
                let second = (try await model.browser.observe())["readings"] as? [String:String] ?? [:]
                let ok = !first.isEmpty && first != second && page["mediaPrimary"] as? Bool == false
                try JSONSerialization.data(withJSONObject:["ok":ok,"modelGenerationTested":false,"first":first,"second":second,"selector":selector],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-clock-readings.json"))
                exit(ok ? 0 : 1)
            }
            guard model.settings.main.isConfigured else { throw AgentError.message("Configure a model in Settings before running a live provider check.") }
            stage = "Reading existing Keychain credential"
            guard !(try await SecretStore.load("main")).isEmpty else { throw AgentError.message("No saved model key is available to this test process") }
            stage = "Generating with configured provider"
            let plan = try await model.adaptive.compose(page).validated(observation:page)
            guard let markup = plan.markup, !markup.compactHTML.isEmpty, plan.readings?.isEmpty == false,
                  !plan.bindings.contains(where:{$0.action == "media"}) else { throw AgentError.message("Provider must generate a live non-media compact card") }
            stage = "Checking generated live card"
            model.install(plan); model.upsertWebTask(plan,activate:true); model.collapse(); delegate.panel.orderFrontRegardless()
            try await Task.sleep(for:.seconds(2))
            let first = model.selectedSideTask?.liveValues ?? [:]
            try await Task.sleep(for:.seconds(2))
            let second = model.selectedSideTask?.liveValues ?? [:]
            guard !second.isEmpty, first != second, model.microMediaTasks.isEmpty else { throw AgentError.message("Clock readings must advance and must not be a player") }
            try await SideScreenCheck.snapshot(delegate.panel,path:"/tmp/orvlet-clock-compact.png")
            model.selectTask(model.browser.id,expanded:true,preferSource:false)
            try await Task.sleep(for:.seconds(1))
            try await SideScreenCheck.snapshot(delegate.panel,path:"/tmp/orvlet-clock-expanded.png")
            let result: [String:Any] = ["ok":true,"plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)),"first":first,"second":second,"mediaPrimary":page["mediaPrimary"] ?? false]
            try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-clock-check.json"))
            exit(0)
        } catch {
            try? JSONSerialization.data(withJSONObject:["ok":false,"stage":stage,"error":error.localizedDescription],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-clock-check.json"))
            exit(1)
        }
    }
}
#endif
