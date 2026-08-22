import AppKit
import ApplicationServices
import SwiftUI

/// Borderless full-screen window hosting the session grid.
@MainActor
final class OverlayWindowController {

    private var window: PanelWindow?
    private unowned let controller: AppController
    /// Whoever was frontmost when we opened, so dismissing can hand focus straight back.
    private var previousApp: NSRunningApplication?
    /// Pending end of the key-swallowing grace period — see `hide`.
    private var teardown: DispatchWorkItem?

    /// How long the invisible window keeps key focus after a dismissal. Long enough to cover a
    /// held Esc and a reflexive second tap, short enough that nobody notices the terminal took
    /// a moment to come back — you are not typing into it yet at this point.
    private static let escGrace: TimeInterval = 0.35

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        // Reopening during the grace period: cancel the teardown and reuse the window, which is
        // still up and merely transparent.
        teardown?.cancel()
        teardown = nil

        let window = self.window ?? makeWindow()
        self.window = window
        window.alphaValue = 1
        window.ignoresMouseEvents = false

        previousApp = NSWorkspace.shared.frontmostApplication

        // A copy still up on *another* desktop is what drags the user over to that desktop:
        // "switch to a Space with open windows for the application" is on by default, so
        // activating an app whose window lives elsewhere moves you there, and the half-second
        // swoosh is most of what reads as Fleet being slow. Taking it down first leaves the app
        // with no window anywhere, so the reopen below lands on the desktop asked from.
        if window.isVisible && !window.isOnActiveSpace {
            window.orderOut(nil)
        }

        window.setFrame(Self.activeScreen().frame, display: true)
        // Order in *before* activating. Activation alone would pull us to whichever Space
        // macOS last associated the app with; putting the window up first means the Space
        // we join is the one the user is looking at, and the activation just gives it focus.
        window.orderFrontRegardless()
        // Accessory apps need an explicit activation to take key focus and receive clicks.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        claimFocus(window)
    }

    /// Make sure the panel actually got the keyboard, and take it by force if not.
    ///
    /// macOS 14 turned activation from something an app does into something the system grants.
    /// A request carrying a user event behind it — the hotkey, the menu bar, `fleet` — is
    /// honoured; the same call from a timer, with the machine untouched for forty-five seconds,
    /// is quietly declined. The window still comes to the front, because `orderFrontRegardless`
    /// is not activation, which is exactly what makes the failure so confusing: the panel is
    /// right there, and it is deaf. No caret in the field, Esc going to the terminal
    /// underneath, ⌘ never reaching the todo column.
    ///
    /// The Accessibility API does not go through cooperative activation, and Fleet already
    /// holds that grant to raise a terminal across a desktop. Asked a beat later rather than
    /// immediately: `makeKey` on an app that is mid-activation reports not-key for a moment and
    /// then becomes key on its own, and there is no point fighting the path that works.
    private func claimFocus(_ window: PanelWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusCheck) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controller.isPanelVisible, !window.isKeyWindow else { return }
                guard Desktop.accessibilityTrusted(prompt: false) else {
                    NSLog("Fleet: the panel is up without the keyboard, and Accessibility is "
                          + "not granted — nothing left to try. System Settings → Privacy & "
                          + "Security → Accessibility.")
                    return
                }
                let me = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString,
                                             kCFBooleanTrue)
                window.makeKey()
                NSLog("Fleet: activation was declined, took the keyboard through Accessibility "
                      + "— key now: \(window.isKeyWindow)")
            }
        }
    }

    /// Long enough for a granted activation to land, short enough that nobody types into the
    /// gap: the panel opens on an idle machine, so the first keystroke is a while away.
    private static let focusCheck: TimeInterval = 0.12

    /// Dismissal is in two beats. The window goes transparent immediately, so it reads as gone,
    /// but stays on screen and *stays key* for a moment before we actually order it out.
    ///
    /// That gap exists to protect the session underneath. Esc dismisses the panel, and the key
    /// press that dismissed it is consumed by us — but a held Esc keeps auto-repeating, and
    /// people tap it twice out of habit. Order out at once and those strays land in the terminal
    /// that just got focus back, where Esc cancels whatever Claude is doing: the user glanced at
    /// the panel and interrupted a session as a side effect. Genuinely swallowing keys aimed at
    /// another app would need a `CGEventTap` and the Accessibility permission Fleet does without,
    /// so instead we stay the key window — invisible and click-through — until the press is over.
    func hide() {
        guard let window, teardown == nil else { return }
        window.alphaValue = 0
        // Invisible but still on screen would otherwise eat a click meant for what's behind it.
        window.ignoresMouseEvents = true

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.teardown = nil
                window.orderOut(nil)
                window.alphaValue = 1
                // Deliberately not `NSApp.hide`: a hidden app is remembered as belonging to the
                // Space it was hidden on, and the next unhide drags the user back to that Space.
                // Handing focus back to the app that had it avoids that side effect.
                self.restorePreviousApp()
            }
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.escGrace, execute: work)
    }

    /// Focus back to whatever we interrupted. Falls back to `NSApp.deactivate` when that app
    /// is gone (quit while the panel was up) or is us.
    private func restorePreviousApp() {
        defer { previousApp = nil }
        // The user may have clicked straight through the invisible window into some other app
        // during the grace period. If we are no longer frontmost, that was their choice — don't
        // drag focus back to whatever happened to be there before the panel opened.
        guard NSApp.isActive else { return }
        guard let app = previousApp,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            NSApp.deactivate()
            return
        }
        app.activate()
    }

    /// The screen the user is actually on. `NSScreen.main` is the one holding the key window,
    /// which for a background agent with nothing on screen can name a display on another
    /// Space; the pointer is a truthful stand-in for "here".
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Dismiss without `NSApp.hide`. Hiding makes macOS activate whatever was frontmost
    /// before us, asynchronously — which lands *after* an activation we perform ourselves and
    /// silently undoes it. When we are about to raise a terminal, we just drop the window.
    func dismissForHandoff() {
        // No grace period here: this path ends in a terminal being raised deliberately, and the
        // trigger was a click, so there is no key press still in flight to absorb.
        teardown?.cancel()
        teardown = nil
        window?.alphaValue = 1
        window?.orderOut(nil)
        previousApp = nil
    }

    private func makeWindow() -> PanelWindow {
        let window = PanelWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        // Without this macOS picks an appearance animation from the style mask, and a
        // borderless window gets the utility-panel one: a scale up from ~90% with a fade.
        // The panel is a glance, so it should already be there when you look at it.
        window.animationBehavior = .none
        // `moveToActiveSpace`, not `canJoinAllSpaces`. Joining all spaces sounds like the right
        // answer for a panel that should appear wherever you are, but it makes the window a
        // permanent resident of every desktop: `isOnActiveSpace` is then always true, there is
        // no such thing as "still open over there" to detect, and macOS still had its own idea
        // of which desktop the app belonged to. Moving one window to the desktop that asked for
        // it is the behaviour actually wanted, and it is observable.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in self?.controller.escape() }
        window.onModifiers = { [weak self] flags in self?.controller.modifiersChanged(flags) }
        window.onNumber = { [weak self] n in self?.controller.activate(number: n) ?? false }
        window.onReturn = { [weak self] in self?.controller.submitPrompt() ?? false }

        let root = OverlayView(controller: controller)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        return window
    }
}

/// Borderless windows refuse key focus by default, and Esc has to reach us.
final class PanelWindow: NSWindow {
    private static let escKeyCode: UInt16 = 53
    /// Return and the numeric keypad's Enter — both send the prompt.
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    var onCancel: (() -> Void)?
    /// Every change to the modifier keys while the panel holds focus. ⌘ turns the todo column
    /// from a list into a set of controls, so the panel has to know it is being held.
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    /// ⌘ and a digit. Returns whether a session wore that number.
    var onNumber: (Int) -> Bool = { _ in false }
    /// Return, with no Shift. Returns whether it was used — when it isn't, the key goes on to
    /// the field as an ordinary newline.
    var onReturn: () -> Bool = { false }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Kept as a breadcrumb rather than a fix. The panel's whole keyboard story depends on it
    /// holding key focus — losing it mid-sentence sends the rest of what you type into whatever
    /// app took it. If that ever happens, this names the culprit instead of leaving it to
    /// guesswork.
    /// The digit of a ⌘-digit chord, or nil for anything else. Read from
    /// `charactersIgnoringModifiers`, so it is the digit printed on the key whatever the layout
    /// underneath — and so ⌘⇧1 counts, which on some layouts sends a different character.
    private static func digit(in event: NSEvent) -> Int? {
        guard event.modifierFlags.contains(.command),
              let text = event.charactersIgnoringModifiers,
              let value = Int(text), (1 ... 9).contains(value) else { return nil }
        return value
    }

    override func resignKey() {
        super.resignKey()
        NSLog("Fleet: panel lost key focus to "
              + (NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"))
    }

    /// Esc and Return are claimed here rather than in `keyDown`, because `keyDown` is the *end*
    /// of the responder chain and both SwiftUI and the field editor are ahead of us in it.
    /// `sendEvent` runs before the event is dispatched to any responder, which is the only
    /// place to win that race. Every other key, Space included, is left alone — it belongs to
    /// the prompt field, which has the caret.
    override func sendEvent(_ event: NSEvent) {
        // Type first, always. `keyCode` is only meaningful on a key event — read it off a
        // mouse event and you get a junk value, and then this method silently eats clicks
        // instead of passing them to the panel.
        switch event.type {
        case .flagsChanged:
            onModifiers?(event.modifierFlags)
            super.sendEvent(event)
        case .keyDown where event.keyCode == Self.escKeyCode:
            // Esc is taken here rather than in `cancelOperation` for the same reason as Space:
            // once the prompt field has focus, the field editor answers Esc first and would
            // swallow the dismissal.
            //
            // Auto-repeats from a held Esc are dropped on the floor: dismissing once is the
            // whole intent, and every repeat we consume is one that cannot reach the session
            // underneath and cancel it. Same for the key-up below.
            if !event.isARepeat { onCancel?() }
            return
        case .keyUp where event.keyCode == Self.escKeyCode:
            return
        case .keyDown where Self.digit(in: event) != nil:
            // ⌘1 through ⌘9 go to the session wearing that number, which is the tile in that
            // position — the grid is laid out by number precisely so the two agree. Matched in
            // the `where` clause rather than inside the case, so every other ⌘ chord falls
            // through to the cases below instead of being handled here and swallowed.
            if let digit = Self.digit(in: event), onNumber(digit) { return }
            super.sendEvent(event)
        case .keyDown where Self.returnKeyCodes.contains(event.keyCode)
            && !event.modifierFlags.contains(.shift):
            // Sending the prompt is claimed from the field editor, which would otherwise
            // insert a newline: the field wraps vertically, so Return is not its own submit.
            // Shift-Return is left alone, which is how you get a second paragraph.
            if onReturn() { return }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}
