import AppKit
import ApplicationServices

/// Getting a terminal window in front of you, wherever macOS has put it.
///
/// Two gestures, both through the Accessibility API:
///
/// **Raising** is how you cross a Space. Activating an application only makes it frontmost —
/// if its window lives on another desktop, or on another display with its own Spaces, you stay
/// exactly where you are and the click appears to do nothing. `AXRaise` is the one gesture
/// macOS honours by switching to the window's desktop, which is what makes clicking a tile
/// actually take you to the session.
///
/// **Fullscreen** is how a window gets a desktop of its own. macOS exposes no public API for
/// creating a Space — the private one costs a partly disabled SIP — and native fullscreen is
/// the one thing that does create one, better behaved than a real Space besides: the desktop is
/// disposed of with the window, so a session never leaves an empty bureau behind. Used when
/// starting a session, not when raising one — see `Config.openInOwnDesktop`.
///
/// Driven straight through Accessibility rather than System Events, which cannot see a window
/// that is not on the active desktop at all: `tell process "Terminal" to window 1` fails with
/// "invalid index" in exactly the case that matters here.
@MainActor
enum Desktop {

    /// Bring `pid`'s frontmost window here, switching desktops if that is where it lives.
    static func raise(pid: pid_t, within timeout: TimeInterval = 2) {
        poll(pid: pid, timeout: timeout, what: "raise") { window in
            AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
    }

    /// Every running instance of `bundleID`, not the first one found.
    ///
    /// Two copies of the same terminal run at once more often than you would think — a second
    /// launch from a different path, a relaunch that left the old one alive — and they are
    /// separate processes with separate windows. Picking the first cost an afternoon here: the
    /// instance `NSWorkspace` happened to list first owned no windows at all, so every lookup
    /// came back empty while four windows sat in the other one.
    private static func instances(of bundleID: String) -> [AXUIElement] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Every window every instance of `bundleID` has, wherever macOS has put it — also the
    /// "before" the new-window search compares against.
    ///
    /// Across desktops, not just this one. `AXWindows` was long believed here to list only the
    /// active desktop's windows; it does not, which is what makes raising across a Space work
    /// at all. What a window created while you watch cannot be is a member of a list taken
    /// beforehand, and that, rather than the desktop it sits on, is what tells it apart.
    static func windows(ofBundle bundleID: String) -> [AXUIElement] {
        instances(of: bundleID).flatMap { windows(of: $0) }
    }

    /// Give the window a terminal has *just opened* a desktop of its own.
    ///
    /// The new window is found by elimination against `existing` rather than by asking which
    /// one has focus. Focus was the original approach and it fails in the case that matters: if
    /// any terminal window is already fullscreen — which is exactly what the last Fleet-started
    /// session leaves behind — the focused window is that one, not the new one, and the session
    /// you just started ends up sharing its predecessor's desktop or none at all.
    static func sendNewWindowToOwnDesktop(bundleID: String, notIn existing: [AXUIElement],
                                          within timeout: TimeInterval = 4) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                // `do script` returns as soon as the command is sent, before the window server
                // has placed anything, so the new window is not there on the first pass.
                if let fresh = windows(ofBundle: bundleID).first(where: { window in
                    !existing.contains { CFEqual($0, window) }
                }) {
                    if fullscreen(fresh) {
                        NSLog("Fleet: the new session has a desktop of its own")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            NSLog("Fleet: the session started, but could not be given its own desktop")
        }
    }

    /// Title and placement of every window an app has on this desktop — the observer for
    /// `--windows`. Answering "did that actually go fullscreen" from outside is otherwise
    /// impossible: AppleScript cannot see across Spaces, and Terminal's own dictionary has no
    /// notion of fullscreen at all.
    static func describeWindows(ofBundle bundleID: String) -> [String] {
        windows(ofBundle: bundleID).map { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            var full: CFTypeRef?
            AXUIElementCopyAttributeValue(window, fullScreenAttribute, &full)
            let mark = full as? Bool == true ? "fullscreen" : "on a shared desktop"
            return "\(mark)  \(title as? String ?? "—")"
        }
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Put one window fullscreen, reporting whether it actually went.
    private static func fullscreen(_ window: AXUIElement) -> Bool {
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, fullScreenAttribute,
                                            &current) == .success else { return false }
        if current as? Bool == true { return true }

        // Read back rather than trusting the return code: setting this on a window that is not
        // on the active Space returns `kAXErrorSuccess` and does nothing whatsoever.
        AXUIElementSetAttributeValue(window, fullScreenAttribute, kCFBooleanTrue)
        var after: CFTypeRef?
        AXUIElementCopyAttributeValue(window, fullScreenAttribute, &after)
        return after as? Bool == true
    }

    /// Runs `act` on the app's focused window until it reports success or the time is up.
    ///
    /// Polled rather than slept against. A window that was just asked for does not exist yet —
    /// `do script` returns as soon as the command is sent, before the window server has placed
    /// anything — and an app that was just activated has not necessarily finished taking focus.
    /// A fixed delay is either a stall or a race, and on a cold Terminal launch it is both.
    private static func poll(pid: pid_t, timeout: TimeInterval, what: String,
                             act: @escaping @MainActor (AXUIElement) -> Bool) {
        let element = AXUIElementCreateApplication(pid)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let window = target(of: element), act(window) { return }
                try? await Task.sleep(for: .milliseconds(60))
            }
            NSLog("Fleet: could not \(what) the window of pid \(pid)")
        }
    }

    /// The window to act on: the focused one, and failing that the app's first.
    ///
    /// The focused window is the better answer when there is one — a terminal opens its new
    /// window frontmost, and activating an app focuses the window holding the tab we just
    /// selected. But an instance whose only window sits on another desktop has *no* focused
    /// window: `AXFocusedWindow` answers `kAXErrorNoValue`, and asking for it alone is what
    /// made clicking a tile do nothing at all — the one case the whole raise exists for.
    ///
    /// `AXWindows` does list that window, contrary to the belief this was written on. What it
    /// leaves out is windows of *other* instances, which is not a problem here: the pid is the
    /// one hosting the session, and its first window is the one `TerminalFocus` has just moved
    /// to the front of that instance's ordering.
    private static func target(of app: AXUIElement) -> AXUIElement? {
        focusedWindow(of: app) ?? windows(of: app).first
    }

    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Not in the `kAX…` constants: fullscreen is a window attribute AppKit publishes but the
    /// framework headers never named.
    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// Both gestures need Fleet itself to be trusted for Accessibility — a separate grant from
    /// the Automation one, in a separate System Settings pane. Checked up front rather than
    /// attempted: an untrusted process is not refused, it is simply shown an empty accessibility
    /// tree, so the failure would look like a window that never opened.
    ///
    /// `prompt` asks macOS to put up the grant dialog. Worth it the first time a session is
    /// started or raised, and not worth it on a poll.
    @discardableResult
    static func accessibilityTrusted(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary) else {
            NSLog("Fleet: no Accessibility grant — a click can raise the terminal app but not "
                  + "cross a desktop. Enable Fleet in System Settings → Privacy & Security → "
                  + "Accessibility.")
            return false
        }
        return true
    }
}
