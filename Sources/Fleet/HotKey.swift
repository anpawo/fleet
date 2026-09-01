import AppKit
import Carbon.HIToolbox

/// What each hotkey does, by id. A plain global, not a member of `HotKey`: the Carbon callback
/// is a C function pointer and so may not capture anything — including an actor-isolated static.
private nonisolated(unsafe) var hotKeyActions: [UInt32: @Sendable () -> Void] = [:]

/// The system-wide chords: one raises the panel, one mutes the idle trigger.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`, because the
/// monitor API needs Accessibility permission — a TCC prompt for a background agent that has
/// no UI to explain itself — while hotkey registration needs nothing at all. It is also the
/// only way to *consume* the chord, so the frontmost app never sees it.
@MainActor
enum HotKey {

    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var handler: EventHandlerRef?

    /// Binds a chord. Rebinding the same id releases the old chord first, so changing the
    /// shortcut in the menu takes effect without a restart. Returns false when something else
    /// already owns the chord — the whole point of a global hotkey is exclusivity, so the OS
    /// refuses a second claimant.
    @discardableResult
    static func register(_ chord: Settings.Chord, id: UInt32,
                         action: @escaping @Sendable () -> Void) -> Bool {
        guard installHandler() else { return false }
        unregister(id: id)
        hotKeyActions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464C_5421), id: id)   // 'FLT!'
        let status = RegisterEventHotKey(UInt32(chord.keyCode), chord.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Fleet: could not register \(chord.label) (\(status)) — another app likely "
                  + "owns it")
            return false
        }
        refs[id] = ref
        return true
    }

    static func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        hotKeyActions[id] = nil
    }

    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            // Which chord fired: the handler is installed once for all of them.
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let fired = id.id
            DispatchQueue.main.async { hotKeyActions[fired]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            NSLog("Fleet: hotkey handler failed (\(status))")
            return false
        }
        return true
    }
}
