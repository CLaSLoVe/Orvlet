import AppKit
import Carbon

enum SummonShortcut: String, Codable, CaseIterable {
    case optionSpace, controlOptionSpace, commandShiftSpace
    var title: String {
        switch self { case .optionSpace: return "⌥ Space"; case .controlOptionSpace: return "⌃⌥ Space"; case .commandShiftSpace: return "⇧⌘ Space" }
    }
    var modifiers: UInt32 {
        switch self { case .optionSpace: return UInt32(optionKey); case .controlOptionSpace: return UInt32(controlKey | optionKey); case .commandShiftSpace: return UInt32(cmdKey | shiftKey) }
    }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func register(_ shortcut: SummonShortcut) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
                guard let pointer else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
                Task { @MainActor in owner.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        return RegisterEventHotKey(UInt32(kVK_Space), shortcut.modifiers, EventHotKeyID(signature:0x4F52564C,id:1), GetApplicationEventTarget(),0,&hotKey) == noErr
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
