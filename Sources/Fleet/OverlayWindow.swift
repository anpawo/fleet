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

        OverlayView.columnHeight = OverlayView.measuredColumnHeight()
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
        host?.dropTrace()
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
        // The user may have clicked straight through the invisible window into some other app
        // during the grace period. If we are no longer frontmost, that was their choice — don't
        // drag focus back to whatever happened to be there before the panel opened. Kept for
        // `passFocusOn`.
        guard NSApp.isActive else { return }
        defer { previousApp = nil }
        guard let app = previousApp,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            NSApp.deactivate()
            return
        }
        app.activate()
    }

    /// Activated with nothing up. alt-tab closed the panel by taking focus, and cancelling it
    /// hands focus back to the app it took it from, which is us: it goes on to the app the panel
    /// was opened over rather than staying with an app that has no window to type into.
    func passFocusOn() {
        guard teardown == nil, NSApp.keyWindow == nil else { return }
        restorePreviousApp()
    }

    /// The screen the user is actually on. `NSScreen.main` is the one holding the key window,
    /// which for a background agent with nothing on screen can name a display on another
    /// Space; the pointer is a truthful stand-in for "here".
    static func activeScreen() -> NSScreen {
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
        host?.dropTrace()
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
        window.onReturn = { [weak self] in self?.controller.submitPrompt() ?? false }

        let root = OverlayView(controller: controller)
        let hosting = FrameCountingHost(rootView: root)
        window.contentView = hosting
        return window
    }

    /// Builds the panel once, right after launch, in the window nobody has asked for yet.
    /// Left to the first open, that build is what the open waited on: 250 ms after a restart,
    /// against 20 to 75 for every open after it (frames logged 2026-10-12).
    func prebuild() {
        guard window == nil else { return }
        let began = CACurrentMediaTime()
        let window = makeWindow()
        self.window = window
        window.setFrame(Self.activeScreen().frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        NSLog(String(format: "Fleet: panel built ahead of its first open, in %.0f ms",
                     (CACurrentMediaTime() - began) * 1000))
    }

    private var host: FrameCountingHost? { window?.contentView as? FrameCountingHost }

    /// What the panel is about to do, as one line in the log — see `FrameCountingHost.trace`.
    /// Timed from here, the window's first making included.
    func trace(_ what: String, lasting: TimeInterval) {
        let asked = CACurrentMediaTime()
        let window = self.window ?? makeWindow()
        self.window = window
        host?.trace(what, asked: asked, lasting: lasting)
    }
}

/// The panel's hosting view, keeping what each frame it rendered cost the main thread. SwiftUI
/// renders inside `layout()`, once per frame of an animation, so this is the frame itself —
/// which a loop around the run loop cannot time: it sees its own turns, not the frames.
final class FrameCountingHost: NSHostingView<OverlayView> {
    struct Frame {
        /// On the wall clock: the gaps between two are what the eye gets.
        var began: CFTimeInterval, ended: CFTimeInterval
        /// In ms of the main thread's CPU.
        var cost: Double
    }

    /// Only while something reads them, the bench or a trace: the app runs for days.
    var counting = false
    var frames: [Frame] = []
    /// The thread's CPU clock as the first frame since `frames` was emptied came out.
    var firstFrameAt = 0.0
    private var tracing: DispatchWorkItem?

    static func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000
    }

    override func layout() {
        guard counting else { return super.layout() }
        let began = CACurrentMediaTime(), start = Self.cpu()
        super.layout()
        let end = Self.cpu()
        if frames.isEmpty { firstFrameAt = end }
        frames.append(Frame(began: began, ended: CACurrentMediaTime(), cost: end - start))
    }

    /// How long a trace waits for its frames: a first one that takes most of a second to come
    /// is the one worth a line.
    private static let traced: TimeInterval = 1

    /// One line in the log for something the user just asked of the panel, once it has played
    /// out: how long the first frame took to come, then how evenly the move's other frames
    /// followed for the `lasting` seconds it runs. `--bench-panel` times the same frames in a
    /// window nobody sees; this is the one on the screen, on the machine as it is that minute.
    /// What it cannot see is the compositor: a frame handed over on time and shown late.
    func trace(_ what: String, asked: CFTimeInterval, lasting: TimeInterval) {
        guard tracing == nil else { return }
        counting = true
        frames = []
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropTrace()
                // A layout that found nothing to do is not a frame.
                let drawn = self.frames.filter { $0.cost > 0.05 }
                guard let first = drawn.first else {
                    NSLog("Fleet: frames — \(what): none in \(Int(Self.traced * 1000)) ms")
                    return
                }
                var line = String(format: "first after %.0f ms (%.1f of main thread)",
                                  (first.ended - asked) * 1000, first.cost)
                let move = drawn.filter { $0.began <= first.began + lasting }
                if let last = move.last, move.count > 1 {
                    let gaps = zip(move, move.dropFirst()).map { ($1.began - $0.began) * 1000 }
                    let costs = move.dropFirst().map(\.cost)
                    line += String(format: ", %d more in %.0f ms, worst gap %.0f ms, %.1f ms of main thread each (worst %.1f)",
                                   costs.count, (last.began - first.began) * 1000, gaps.max() ?? 0,
                                   costs.reduce(0, +) / Double(costs.count), costs.max() ?? 0)
                }
                NSLog("Fleet: frames — \(what): \(line)")
            }
        }
        tracing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.traced, execute: work)
    }

    /// The panel went away under it: frames of a window nobody sees are not worth a line.
    func dropTrace() {
        tracing?.cancel()
        tracing = nil
        counting = false
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
