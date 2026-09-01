import Carbon.HIToolbox
import Foundation

/// The handful of things the menu lets you change, kept in `UserDefaults` so they survive the
/// restart that every Fleet update ends with.
enum Settings {

    /// A global chord. Carbon modifier mask plus a virtual key code — the two things
    /// `RegisterEventHotKey` wants, stored as they are so nothing has to be translated back.
    struct Chord: Hashable {
        var keyCode: UInt16
        var modifiers: UInt32

        var label: String {
            var out = ""
            if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
            return out + Self.keyNames[keyCode, default: "?"]
        }

        /// Only the keys the presets below use — nothing else can be chosen, so nothing else
        /// needs a name.
        private static let keyNames: [UInt16: String] = [
            UInt16(kVK_ANSI_L): "L", UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_M): "M",
            UInt16(kVK_Space): "Space", UInt16(kVK_Escape): "⎋",
        ]
    }

    /// The chords on offer. A recorder that captures whatever you press would be the general
    /// answer; a list of five is a tenth of the code and covers the chords that are actually
    /// free on this machine.
    static let panelChoices = [
        Chord(keyCode: UInt16(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)),
        Chord(keyCode: UInt16(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey)),
        Chord(keyCode: UInt16(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
        Chord(keyCode: UInt16(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        Chord(keyCode: UInt16(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey)),
    ]

    static let muteChoices = [
        Chord(keyCode: UInt16(kVK_Escape), modifiers: UInt32(cmdKey)),
        Chord(keyCode: UInt16(kVK_Escape), modifiers: UInt32(cmdKey | shiftKey)),
        Chord(keyCode: UInt16(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey)),
        Chord(keyCode: UInt16(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)),
    ]

    /// Offered idle delays, in seconds. `.infinity` is "never on its own" — the panel then only
    /// ever appears because you asked for it.
    static let idleChoices: [TimeInterval] = [15, 30, 45, 60, 120, 300, .infinity]

    static var panelChord: Chord {
        get { chord(forKey: "panelChord") ?? panelChoices[0] }
        set { store(newValue, forKey: "panelChord") }
    }

    static var muteChord: Chord {
        get { chord(forKey: "muteChord") ?? muteChoices[0] }
        set { store(newValue, forKey: "muteChord") }
    }

    /// How long the machine must be untouched before the panel shows itself.
    static var idleThreshold: TimeInterval {
        get {
            guard let stored = UserDefaults.standard.object(forKey: "idleThreshold")
                    as? TimeInterval else { return 45 }
            // Written as 0 by the "never" row: `infinity` does not survive a plist round trip.
            return stored <= 0 ? .infinity : stored
        }
        set {
            UserDefaults.standard.set(newValue.isFinite ? newValue : 0, forKey: "idleThreshold")
        }
    }

    /// How long the mute chord silences the idle trigger for.
    static let muteDuration: TimeInterval = 10 * 60

    private static func chord(forKey key: String) -> Chord? {
        let parts = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ":")
        guard parts.count == 2, let code = UInt16(parts[0]), let mods = UInt32(parts[1])
        else { return nil }
        return Chord(keyCode: code, modifiers: mods)
    }

    private static func store(_ chord: Chord, forKey key: String) {
        UserDefaults.standard.set("\(chord.keyCode):\(chord.modifiers)", forKey: key)
    }
}
