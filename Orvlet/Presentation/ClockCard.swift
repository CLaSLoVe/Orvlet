import Foundation

extension TaskSurface {
    var clockControlState: [String: String] {
        let clocks = runtime?.sources.filter { $0.kind == .clock && $0.format == .time } ?? []
        var values = Dictionary(
            uniqueKeysWithValues: clocks.enumerated().map {
                ("clockZone\($0.offset)", $0.element.timeZone ?? TimeZone.current.identifier)
            })
        values["clockHourStyle"] = clocks.first?.hour12 == true ? "12h" : "24h"
        values["clockLocationLabel"] =
            (clocks.first?.timeZone ?? TimeZone.current.identifier).split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "_", with: " ") ?? "Local"
        return values
    }

    var withClockControls: TaskSurface {
        guard preset == "clock", let runtime else { return self }
        var result = self
        let clocks = runtime.sources.filter { $0.kind == .clock && $0.format == .time }
        result.fields = clocks.indices.map { "clockZone\($0)" } + ["clockHourStyle"]
        result.state.merge(clockControlState) { _, fresh in fresh }
        result.actions = [TaskSurfaceAction(id: "configureClock", kind: .runtime, operation: "configureClock")]
        if let markup = try? BuiltinCards.clock(runtime, interactive: true) { result.markup = markup }
        return result
    }
}

extension AppModel {
    func configureClock(_ id: UUID, fields: [String: String]) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), var surface = sideTasks[i].taskSurface,
            var runtime = surface.runtime, runtime.refresh == nil,
            runtime.sources.allSatisfy({ $0.kind == .clock && [.time, .date].contains($0.format) })
        else { return }
        let clocks = runtime.sources.filter { $0.kind == .clock && $0.format == .time }
        let original = runtime.sources
        var assignedDates = Set<Int>()
        let style = fields["clockHourStyle"] ?? (clocks.first?.hour12 == true ? "12h" : "24h")
        guard ["12h", "24h"].contains(style) else { return }
        for (index, clock) in clocks.enumerated() {
            let old = clock.timeZone ?? TimeZone.current.identifier
            let zone = fields["clockZone\(index)"] ?? old
            guard TimeZone(identifier: zone) != nil,
                let timeIndex = original.firstIndex(where: { $0.key == clock.key })
            else { return }
            runtime.sources[timeIndex].timeZone = zone
            runtime.sources[timeIndex].hour12 = style == "12h"
            if let dateIndex = original.indices.first(where: {
                !assignedDates.contains($0) && original[$0].format == .date
                    && (original[$0].timeZone ?? TimeZone.current.identifier) == old
            }) {
                runtime.sources[dateIndex].timeZone = zone
                assignedDates.insert(dateIndex)
            }
        }
        surface.runtime = runtime
        surface.state.merge(surface.clockControlState) { _, fresh in fresh }
        if surface.preset == "clock" { surface = surface.withClockControls }
        for source in runtime.sources { surface.state[source.key] = source.value(at: Date()) }
        guard let checked = try? surface.validated() else { return }
        taskRuntime.detach(id)
        sideTasks[i].taskSurface = checked
        sideTasks[i].markup = checked.markup
        sideTasks[i].liveValues = checked.state
        taskRuntime.attach(id)
        persistSideTasks()
    }
}
