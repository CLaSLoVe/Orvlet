import AppKit

enum ReminderSound: String, Codable, CaseIterable {
    case slowRise, ripples, harp, canopy
    case alarm, radar, oldPhone, bellTower, digital
    case aurora, anticipate, sherwoodForest, minuet
    case bamboo, complete, input, keys, tink, glass, pop, silent

    var title: String {
        switch self {
        case .slowRise: "Slow Rise"
        case .oldPhone: "Old Phone"
        case .bellTower: "Bell Tower"
        case .sherwoodForest: "Sherwood Forest"
        default: rawValue.capitalized
        }
    }

    private static let alarmTones: [Self] = [.slowRise, .ripples, .harp, .canopy]

    var alarmPreference: Self {
        self == .silent || Self.alarmTones.contains(self) ? self : .slowRise
    }

    var messagePreference: Self {
        self == .silent || Self.messageTones.contains(self) ? self : .bamboo
    }

    private var appleFile: URL? {
        let library = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources")
        let folder: String
        switch self {
        case .canopy: return library.appendingPathComponent("Ringtones/Canopy-EncoreInfinitum.m4r")
        case .slowRise, .ripples, .harp, .alarm, .radar, .oldPhone, .bellTower, .digital: folder = "Ringtones"
        case .aurora, .bamboo, .complete, .input, .keys: folder = "AlertTones/Modern"
        case .anticipate, .sherwoodForest, .minuet: folder = "AlertTones/Classic"
        case .tink, .glass, .pop:
            return URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(title + ".aiff")
        case .silent: return nil
        }
        return library.appendingPathComponent(folder).appendingPathComponent(title + ".m4r")
    }

    var url: URL? {
        guard self != .silent else { return nil }
        let fallback = Self.alarmTones.contains(self) ? Self.alarmTones + [.glass] : [.tink]
        return ([self] + fallback).compactMap(\.appleFile).first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static let messageTones: [Self] = [.bamboo, .complete, .input, .pop, .keys, .tink, .glass]

    static func choices(for persistence: ReminderPersistence, selected: Self) -> [Self] {
        let tones = persistence == .persistent ? alarmTones : messageTones
        var choices = tones.filter { $0.appleFile.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false }
        if selected != .silent && !choices.contains(selected) { choices.append(selected) }
        return choices + [.silent]
    }
}

enum ReminderSoundChannel: Hashable {
    case event(ReminderPersistence)
    case preview
}

struct ActiveReminderSound {
    let player: NSSound
    var eventID: UUID?
    let persistence: ReminderPersistence
}

final class ReminderSoundCompletion: NSObject, NSSoundDelegate {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        Task { @MainActor [weak self] in
            self?.model?.reminderSoundFinished(sound)
        }
    }
}

extension ReminderIntensity {
    var repeatInterval: TimeInterval {
        switch self {
        case .gentle: 12
        case .standard: 5
        case .strong: 3
        }
    }

    func soundVolume(for persistence: ReminderPersistence) -> Float {
        if persistence == .persistent { return self == .gentle ? 0.85 : 1 }
        return switch self {
        case .gentle: 0.22
        case .standard: 0.46
        case .strong: 0.74
        }
    }
}

extension AppModel {
    private var nextAudibleReminder: PresentedCardReminder? {
        reminders.filter { $0.persistence == .persistent }.min { $0.intensity.repeatInterval < $1.intensity.repeatInterval }
    }

    func updateReminderRepeats() {
        guard let interval = nextAudibleReminder?.intensity.repeatInterval else {
            stopReminderRepeats()
            return
        }
        if reminderRepeatTimer?.timeInterval == interval { return }
        stopReminderRepeats()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, timer === self.reminderRepeatTimer, let reminder = self.nextAudibleReminder else {
                    timer.invalidate()
                    return
                }
                guard self.activeReminderSounds[.event(.persistent)]?.player.isPlaying != true else { return }
                self.playReminderSound(intensity: reminder.intensity, eventID: reminder.id)
            }
        }
        timer.fireDate = Date().addingTimeInterval(interval)
        timer.tolerance = 0.15
        reminderRepeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopReminderRepeats() {
        reminderRepeatTimer?.invalidate()
        reminderRepeatTimer = nil
    }

    fileprivate func reminderSoundFinished(_ player: NSSound) {
        guard let channel = activeReminderSounds.first(where: { $0.value.player === player })?.key else { return }
        activeReminderSounds.removeValue(forKey: channel)
        updateReminderMusicGain()
    }

    func stopReminderSound(events: Set<UUID>? = nil) {
        for (channel, sound) in activeReminderSounds {
            if let events {
                guard let id = sound.eventID, events.contains(id) else { continue }
                if channel == .event(.persistent), let remaining = nextAudibleReminder {
                    activeReminderSounds[channel]?.eventID = remaining.id
                    continue
                }
            }
            clearReminderPlayer(in: channel)
        }
        updateReminderMusicGain()
    }

    private func updateReminderMusicGain() {
        let hasAlarm = activeReminderSounds.values.contains { $0.persistence == .persistent }
        playbackCoordinator.setReminderMusicGain(hasAlarm ? 0.10 : activeReminderSounds.isEmpty ? 1 : 0.28)
    }

    func changeReminderTone(for persistence: ReminderPersistence) {
        if persistence == .persistent, let reminder = nextAudibleReminder {
            stopReminderPreview()
            playReminderSound(intensity: reminder.intensity, eventID: reminder.id)
        } else {
            playReminderSound(persistence: persistence)
        }
    }

    func stopReminderPreview() {
        clearReminderPlayer(in: .preview)
        updateReminderMusicGain()
    }

    private func clearReminderPlayer(in channel: ReminderSoundChannel) {
        guard let sound = activeReminderSounds.removeValue(forKey: channel) else { return }
        sound.player.delegate = nil
        sound.player.stop()
    }

    func playReminderSound(intensity: ReminderIntensity = .standard, eventID: UUID? = nil, persistence: ReminderPersistence = .persistent) {
        let channel: ReminderSoundChannel = eventID == nil ? .preview : .event(persistence)
        let sound = settings.sound(for: persistence)
        defer { updateReminderMusicGain() }
        clearReminderPlayer(in: channel)
        guard let url = sound.url else {
            if channel == .preview { clearReminderPlayer(in: .event(persistence)) }
            return
        }
        var volume = intensity.soundVolume(for: persistence)
        #if DEBUG
            if let reminderSoundPlaybackCheck {
                reminderSoundPlaybackCheck(sound, intensity)
                return
            }
            if playsMutedReminderForCheck {
                volume = 0
            } else if isLiveTest || CommandLine.arguments.contains("--background-checks") {
                return
            }
        #else
            guard !isLiveTest else { return }
        #endif
        guard let player = NSSound(contentsOf: url, byReference: true) else { return }
        player.loops = channel == .event(.persistent)
        player.volume = volume
        player.delegate = reminderSoundCompletion
        if player.play() {
            activeReminderSounds[channel] = ActiveReminderSound(player: player, eventID: eventID, persistence: persistence)
        }
    }
}
