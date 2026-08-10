import AppKit
import Carbon.HIToolbox

/// What the hotkey does. A plain global, not a member of `HotKey`: the Carbon callback is a C
/// function pointer and so may not capture anything — including an actor-isolated static.
private nonisolated(unsafe) var hotKeyAction: (@Sendable () -> Void)?

/// A single system-wide hotkey: ⌘⌥L brings the panel to the front.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`, because the
/// monitor API needs Accessibility permission — a TCC prompt for a background agent that has
/// no UI to explain itself — while hotkey registration needs nothing at all. It is also the
/// only way to *consume* the chord, so the frontmost app never sees it.
@MainActor
enum HotKey {

    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    /// Registers ⌘⌥L. Returns false when something else already owns the chord — the whole
    /// point of a global hotkey is exclusivity, so the OS refuses a second claimant.
    @discardableResult
    static func register(_ block: @escaping @Sendable () -> Void) -> Bool {
        guard ref == nil else { return true }
        hotKeyAction = block

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            NSLog("Fleet: hotkey handler failed (\(status))")
            return false
        }

        let id = EventHotKeyID(signature: OSType(0x464C_5421), id: 1)   // 'FLT!'
        let modifiers = UInt32(cmdKey | optionKey)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), modifiers,
                                             id, GetEventDispatcherTarget(), 0, &ref)
        guard registered == noErr else {
            NSLog("Fleet: could not register ⌘⌥L (\(registered)) — another app likely owns it")
            ref = nil
            return false
        }
        return true
    }
}
