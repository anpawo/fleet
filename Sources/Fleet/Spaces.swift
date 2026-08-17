import AppKit

/// Making a desktop — a real Space, the one Mission Control's `+` creates.
///
/// There is no API for this, and the private one is a trap: `CGSSpaceCreate` and friends still
/// exist in SkyLight, but the Dock owns space management, so a space conjured behind its back
/// is not one Mission Control will show you. That is why yabai injects a scripting addition
/// into Dock, and why doing so costs a partly disabled SIP.
///
/// What is left is to press the button ourselves. Mission Control's Spaces bar lives in the
/// Dock's accessibility tree — `Dock → group "Mission Control" → group 1 → group "Spaces Bar"`
/// — and its `+` is an ordinary `AXButton` that anything trusted for Accessibility can click.
/// Nothing is faked and no coordinates are guessed: it is the same click, dispatched by us.
@MainActor
enum Spaces {

    /// Adds a desktop, without going to it. Mission Control has to be on screen for the button
    /// to exist at all, so it is opened, clicked, and toggled shut again — about a second, and
    /// the panel is already gone by then.
    @discardableResult
    static func addDesktop() -> Bool {
        guard Desktop.accessibilityTrusted() else { return false }

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Fleet: could not add a desktop — \(error)")
            return false
        }
        return true
    }

    /// The `+` is addressed as the Spaces bar's only direct button — the desktops themselves
    /// are buttons *inside* its list — rather than by its "add desktop" description, which is
    /// the one part of this that a system language change would move.
    ///
    /// Polled rather than slept against: `launch` returns before Mission Control has drawn, and
    /// the Spaces bar is the last thing to appear. Its presence is also the only honest test of
    /// whether Mission Control is up — the `group "Mission Control"` around it stays in the
    /// tree, empty, long after it has been dismissed.
    private static let script = """
    tell application "Mission Control" to launch
    tell application "System Events"
        tell process "Dock"
            repeat 40 times
                try
                    set bar to first group of (first group of ¬
                        (first group whose name is "Mission Control")) ¬
                        whose name of it is "Spaces Bar"
                    exit repeat
                on error
                    delay 0.05
                end try
            end repeat
            click (first button of bar)
        end tell
    end tell
    -- Long enough for the new thumbnail to land before the window is torn down; the click is
    -- dispatched by then, so this is politeness to the animation rather than a race.
    delay 0.35
    tell application "Mission Control" to launch
    """
}
