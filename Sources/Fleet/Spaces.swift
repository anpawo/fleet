import AppKit
import ApplicationServices

/// Making a desktop — a real Space, the one Mission Control's `+` creates.
///
/// There is no API for this, and the private ones are a dead end rather than a shortcut.
/// `CGSSpaceCreate` still links on macOS 26 (CoreGraphics re-exports the `_CGS*` aliases over
/// SkyLight's `_SLS*`), but every call returns a space id of 0: mutating the space list is
/// gated on `com.apple.private.skylight.universal-owner`, which the Dock has and no
/// third-party signature can be given. Dock's own `createSpaces` XPC message is behind
/// `com.apple.private.dock.spaces`, and nothing shipping on the machine holds that either.
/// `CoreDockSetWorkspacesCount` is an eight-byte stub that returns -50 without so much as
/// contacting the Dock. That is why yabai injects a scripting addition into Dock and calls an
/// unexported function found by byte-pattern scan — and why it costs a partly disabled SIP.
///
/// What is left is to press the button ourselves. Mission Control's Spaces bar lives in the
/// Dock's accessibility tree, and its `+` is an ordinary `AXButton`. Nothing is faked and no
/// coordinates are guessed: it is the same press, dispatched by us, under the Accessibility
/// grant Fleet already needs to raise a terminal across a desktop.
@MainActor
enum Spaces {

    /// Adds a desktop to `display`, without going to it.
    ///
    /// Mission Control has to be on screen for the button to exist at all, so it is opened,
    /// pressed, and toggled shut again — about half a second of it flashing past, which is not
    /// suppressible: every route to a new Space ends at driving the Dock's own interface.
    @discardableResult
    static func addDesktop(on display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard Desktop.accessibilityTrusted() else { return false }

        // Left alone if it was already up — closing something the user opened would be rude,
        // and Fleet's own `+` is only reachable with Mission Control down anyway.
        let opened = missionControl() == nil
        if opened { toggleMissionControl() }

        guard let button = waitForAddButton(on: display) else {
            if opened { toggleMissionControl() }
            NSLog("Fleet: no add-desktop button in Mission Control — the Dock's accessibility "
                  + "tree has moved, or Mission Control never came up")
            return false
        }

        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        // The press is dispatched by now; this is politeness to the animation, so the new
        // thumbnail lands before the window is torn down from under it.
        if opened {
            usleep(250_000)
            toggleMissionControl()
        }
        if !pressed { NSLog("Fleet: the add-desktop button refused the press") }
        return pressed
    }

    /// The `+`, once Mission Control has drawn it. Polled rather than slept against: the
    /// notification returns immediately and the Spaces bar is the last thing to appear.
    ///
    /// Blocking is deliberate. The whole thing is under a second, the panel is already gone by
    /// the time it starts, and every alternative — a detached task, an async ladder — buys
    /// nothing while there is no interface left to keep responsive.
    private static func waitForAddButton(on display: CGDirectDisplayID,
                                         within timeout: TimeInterval = 2) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = addButton(on: display) { return button }
            usleep(20_000)
        }
        return nil
    }

    /// `Dock → mc → mc.display → mc.spaces → mc.spaces.add`.
    ///
    /// Navigated by `AXIdentifier` and never by title or position, which is the whole
    /// difference between this working and the snippets that do not. The descriptions are
    /// localized — Dock's `Accessibility.strings` gives "add desktop" as "ajouter le bureau" in
    /// French — and positional indexing (`group 2 of group 1 of group 1`) is exactly what broke
    /// between Ventura and Sonoma. The `mc.*` identifiers have held since Monterey.
    private static func addButton(on display: CGDirectDisplayID) -> AXUIElement? {
        guard let mc = missionControl() else { return nil }

        // One `mc.display` per screen. Falling back to the first rather than failing: on a
        // single display the match is a formality, and no desktop at all is a worse answer
        // than one on the wrong screen.
        let displays = children(mc).filter { identifier($0) == "mc.display" }
        let screen = displays.first {
            (attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == display
        } ?? displays.first

        guard let screen,
              let spaces = children(screen).first(where: { identifier($0) == "mc.spaces" })
        else { return nil }
        return children(spaces).first { identifier($0) == "mc.spaces.add" }
    }

    /// The `mc` group, which exists only while Mission Control is on screen — making its
    /// presence the honest test of whether Mission Control is up. Asking the window server is
    /// no use: Mission Control owns no window anyone else can see.
    private static func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        return children(element).first { identifier($0) == "mc" }
    }

    /// Show Mission Control, or dismiss it if it is showing.
    ///
    /// The same notification `Mission Control.app` posts — that app is a 100 KB stub whose
    /// entire job this is. Preferred over launching it, or over synthesizing the F3 key: no
    /// Apple Events, so no Automation prompt on top of the Accessibility one, and no
    /// `kTCCServicePostEvent` grant for injecting keystrokes.
    private static func toggleMissionControl() {
        CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)
    }

    // MARK: - Accessibility reads

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, "AXIdentifier") as? String
    }
}

/// Undocumented, but exported from HIServices and callable with no entitlement at all.
@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ name: CFString, _ reserved: Int32)
