import SwiftUI

/// Stable, local transport. Only discovery needs the agent; listening never waits for generated markup.
struct MusicCard: View {
    @ObservedObject var model: AppModel
    let task: SideTask
    @Environment(\.colorScheme) private var scheme
    @State private var seeking = false
    @State private var seekPosition = 0.0
    @State private var showVolume = false
    @State private var editingVolume = false
    @State private var volume = 1.0
    private var state: MusicPlayback { model.musicPlayback[task.id] ?? MusicPlayback() }
    private var queue: MusicQueue { task.musicQueue ?? MusicQueue() }
    private var loading: Bool { model.musicLoading.contains(task.id) }
    private var expanded: Bool { model.musicQueueExpanded.contains(task.id) }
    private var tint: Color { CalmVisualStyle.tint(model.accent, scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(loading ? queue.current?.title ?? task.title : task.title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .lineLimit(2).frame(height: 48, alignment: .topLeading)
                Text(loading ? "Opening on YouTube…" : state.ad ? "YouTube · Advertisement" : subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 3) {
                if state.seekable {
                    Slider(
                        value: Binding(
                            get: { seeking ? seekPosition : min(state.position, state.duration) },
                            set: { seekPosition = $0 }),
                        in: 0...max(1, state.duration),
                        onEditingChanged: { active in
                            seeking = active
                            model.controlInteraction(active)
                            if !active { model.musicControl(task.id, operation: "seek", value: seekPosition) }
                        }
                    )
                    .controlSize(.mini).tint(tint).disabled(loading)
                    .accessibilityLabel("Playback position").accessibilityIdentifier("music-seek")
                    HStack {
                        Text(MusicPlayback.time(seeking ? seekPosition : state.position))
                        Spacer()
                        Text(MusicPlayback.time(state.duration))
                    }.font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(
                        state.ad
                            ? "Playback will continue after the ad"
                            : loading || !state.ready ? "Connecting…" : state.live ? "Live" : "Playback"
                    )
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
            }.frame(height: 32)
            HStack(spacing: 12) {
                icon("Repeat one", symbol: "repeat.1", active: state.looping) {
                    model.musicControl(task.id, operation: state.looping ? "unloop" : "loop")
                }.disabled(loading || !state.seekable).accessibilityIdentifier("music-repeat")
                Spacer(minLength: 0)
                icon("Previous track", symbol: "backward.end.fill") {
                    model.musicControl(task.id, operation: "previous")
                }
                .disabled(loading || queue.previous.isEmpty).accessibilityIdentifier("music-previous")
                Button {
                    model.musicControl(task.id, operation: loading ? "pause" : "toggle")
                } label: {
                    Image(systemName: loading ? "stop.fill" : task.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 40)
                        .foregroundStyle(tint).background(
                            model.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).disabled(!state.ready && !loading)
                    .accessibilityLabel(loading ? "Stop loading" : task.playing ? "Pause" : "Play").help(
                        loading ? "Stop loading" : task.playing ? "Pause" : "Play"
                    )
                    .accessibilityIdentifier("music-playback")
                icon("Next track", symbol: "forward.end.fill") { model.musicControl(task.id, operation: "next") }
                    .disabled(loading || queue.upcoming.isEmpty).accessibilityIdentifier("music-next")
                Spacer(minLength: 0)
                icon("Volume", symbol: state.muted || state.volume == 0 ? "speaker.slash" : "speaker.wave.2") {
                    volume = state.volume
                    showVolume.toggle()
                }.disabled(loading || !state.ready).accessibilityIdentifier("music-volume")
                    .popover(isPresented: $showVolume, arrowEdge: .bottom) {
                        HStack(spacing: 10) {
                            Button {
                                model.musicControl(task.id, operation: "toggleMute")
                            } label: {
                                Image(systemName: state.muted ? "speaker.slash" : "speaker.wave.2")
                            }
                            .buttonStyle(.plain).accessibilityLabel(state.muted ? "Unmute" : "Mute")
                            Slider(
                                value: Binding(get: { editingVolume ? volume : state.volume }, set: { volume = $0 }),
                                in: 0...1,
                                onEditingChanged: { active in
                                    editingVolume = active
                                    model.controlInteraction(active)
                                    if !active { model.musicControl(task.id, operation: "volume", value: volume) }
                                }
                            ).frame(width: 130).controlSize(.small).tint(tint).accessibilityLabel("Music volume")
                        }.padding(14)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if expanded {
                        model.musicQueueExpanded.remove(task.id)
                    } else {
                        model.musicQueueExpanded.insert(task.id)
                    }
                    model.onResize?(model.windowSize)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                        Text("Up next")
                        if !queue.upcoming.isEmpty { Text("\(queue.upcoming.count)").foregroundStyle(.tertiary) }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }.frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("music-queue")
                if expanded {
                    if queue.upcoming.isEmpty {
                        Text("Nothing queued yet").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 30)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(queue.upcoming) { track in
                                    HStack(spacing: 8) {
                                        Button {
                                            model.startQueuedMusic(track, id: task.id)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(track.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                                if !track.subtitle.isEmpty {
                                                    Text(track.subtitle).font(.system(size: 10)).foregroundStyle(
                                                        .secondary
                                                    ).lineLimit(1)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(loading)
                                        Button {
                                            model.removeQueuedMusic(track.id, id: task.id)
                                        } label: {
                                            Image(systemName: "xmark").font(.system(size: 9)).frame(
                                                width: 24, height: 30)
                                        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(
                                            "Remove " + track.title)
                                    }.frame(height: 42)
                                        .draggable(task.id.uuidString + ":" + track.id)
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let value = items.first, value.hasPrefix(task.id.uuidString + ":")
                                            else { return false }
                                            model.moveQueuedMusic(
                                                String(value.dropFirst(37)), before: track.id, id: task.id)
                                            return true
                                        }
                                }
                            }
                        }.frame(height: Double(min(queue.upcoming.count, 4)) * 42)
                    }
                }
            }
            if let error = model.musicErrors[task.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("music-error")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear {
                if seeking {
                    model.controlInteraction(false)
                    seeking = false
                }
                if editingVolume {
                    model.controlInteraction(false)
                    editingVolume = false
                }
            }
    }
    private var subtitle: String {
        let text = state.subtitle.isEmpty ? queue.current?.subtitle ?? "" : state.subtitle
        return text.isEmpty ? "YouTube" : text + " · YouTube"
    }
    private func icon(_ label: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 32)
                .foregroundStyle(active ? tint : .secondary)
                .background(active ? model.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityValue(active ? "On" : "")
    }
}
