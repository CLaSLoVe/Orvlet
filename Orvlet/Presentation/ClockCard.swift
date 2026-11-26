import Foundation

extension TaskSurface {
    func clockOffsets(at date: Date) -> [String: String] {
        let clocks = runtime?.sources.filter { $0.kind == .clock && $0.format == .time } ?? []
        var offsets = [String: String]()
        for (index, clock) in clocks.enumerated() {
            let zone = clock.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            let seconds = zone.secondsFromGMT(for: date)
            let minutes = abs(seconds) / 60
            let sign = seconds < 0 ? "−" : "+"
            let offset = minutes % 60 == 0 ? String(minutes / 60) : String(format: "%d:%02d", minutes / 60, minutes % 60)
            offsets["clockUTCOffset\(index)"] = seconds == 0 ? "UTC" : "UTC" + sign + offset
        }
        return offsets
    }

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
        return values.merging(clockOffsets(at: Date())) { _, fresh in fresh }
    }

    var withClockControls: TaskSurface {
        guard preset == "clock", let runtime else { return self }
        var result = self
        let clocks = runtime.sources.filter { $0.kind == .clock && $0.format == .time }
        result.fields = clocks.indices.map { "clockZone\($0)" } + ["clockHourStyle"]
        result.state.merge(clockControlState) { _, fresh in fresh }
        result.actions = [TaskSurfaceAction(id: "configureClock", kind: .runtime, operation: "configureClock")]
        if var markup = try? BuiltinCards.clock(runtime, interactive: true) {
            markup.interfaceLanguage = self.markup.interfaceLanguage
            result.markup = markup
        }
        return result
    }
}

extension AppModel {
    func configureClock(_ id: UUID, fields: [String: String]) {
        let artifact = work.artifact(id) ?? work.view(id).flatMap { work.artifact($0.selected) }
        let i = sideTasks.firstIndex(where: { $0.id == id })
        guard var surface = artifact.flatMap({ try? workSurface($0) }) ?? i.flatMap({ sideTasks[$0].taskSurface }),
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
        if zip(clocks, runtime.sources.filter({ $0.kind == .clock && $0.format == .time })).contains(where: { $0.timeZone != $1.timeZone }) {
            var seen = Set<String>()
            surface.title = runtime.sources.filter { $0.kind == .clock && $0.format == .time }.map {
                (($0.timeZone ?? TimeZone.current.identifier).split(separator: "/").last.map(String.init) ?? "Local").replacingOccurrences(of: "_", with: " ")
            }.filter { seen.insert($0).inserted }.joined(separator: ", ")
        }
        surface.state.merge(surface.clockControlState) { _, fresh in fresh }
        if surface.preset == "clock" { surface = surface.withClockControls }
        for source in runtime.sources { surface.state[source.key] = source.value(at: Date()) }
        guard let checked = try? surface.validated() else { return }
        if let artifact {
            if work.update(artifact.id, expecting: artifact.revision, {
                $0.definition = WorkDefinition(surface: checked)
                $0.values = checked.state; $0.title = checked.title
            }) {
                projectWorkResult(artifact.id)
                taskRuntime.attach(artifact.id)
            }
            persistSideTasks()
            return
        }
        guard let i else { return }
        taskRuntime.detach(id)
        sideTasks[i].title = checked.title
        sideTasks[i].taskSurface = checked
        sideTasks[i].markup = checked.markup
        sideTasks[i].liveValues = checked.state
        taskRuntime.attach(id)
        persistSideTasks()
    }
}
