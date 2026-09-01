import AppKit
import Combine
import IOKit.pwr_mgt

/// Drives the whole app: watches for idle, decides when the panel appears, and keeps the
/// wakeup cadence as low as the current situation allows.
///
/// Battery profile, cheapest state first:
///   • no sessions   — one `proc_listpids` every 60s, nothing else
///   • sessions live — a full refresh every 5s, but only transcripts whose tail moved are
///                     re-parsed; the rest is one `stat` each
///   • panel visible — the same refresh every 1s, so tiles track their sessions live
/// The timer carries a 50% tolerance so macOS coalesces these wakeups with other timers
/// rather than waking the CPU just for us, and everything stops entirely on sleep.
@MainActor
final class AppController: ObservableObject {

    @Published private(set) var sessions: [Session] = [] {
        didSet {
            statusItem?.update(sessions: sessions)
            notifier.update(sessions: sessions, panelVisible: isPanelVisible)
        }
    }
    @Published private(set) var isPanelVisible = false
    /// Whether ⌘ is down right now. The todo column grows a ✕ on every row while it is, so a
    /// list you can only read becomes a list you can clear without ever leaving the panel.
    @Published private(set) var commandHeld = false

    /// The two side columns: the mail worth reading and the todo list, both from the phone's
    /// Firestore project. Owned here so what arrived last outlives the panel being dismissed.
    let hub = HubStore()

    private let registry = SessionRegistry()
    private let notifier = Notifier()
    private var overlay: OverlayWindowController?
    private var statusItem: StatusItemController?
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var suspended = false

    /// Guards against the panel reappearing the instant it is dismissed. Re-arms only once
    /// the user has been active again.
    private var armed = true

    func start() {
        overlay = OverlayWindowController(controller: self)
        statusItem = StatusItemController(controller: self)
        notifier.start()
        // A banner names a session; clicking it should land you in that session, which is the
        // same handoff a tile click does.
        notifier.onSelect = { [weak self] pid in
            guard let self, let session = sessions.first(where: { $0.id == pid }) else { return }
            activate(session)
        }
        // State left behind by sessions that ended without saying so — a killed terminal, a
        // crash. Once at launch is enough; nothing else creates them.
        Hooks.prune()
        observeSleepWake()
        schedule(Config.idlePollDormant)
        tick()
    }

    /// `--render`: populate the panel without any window, for offscreen image rendering.
    func injectSessions(_ found: [Session]) {
        sessions = found
    }

    /// `--fake <n>`: a fleet that isn't there, so the panel can be looked at — and scrolled —
    /// at sizes you do not happen to have running. Held rather than refreshed into, or the
    /// next tick would replace it with the real fleet a second later.
    var pretendFleet: [Session]? {
        didSet { if let pretendFleet { sessions = pretendFleet } }
    }

    /// Manual trigger — Spotlight, the `fleet` command, `--demo`. Skips the idle timer
    /// entirely so the panel is available the moment you want to check on things, and toggles
    /// so triggering it twice puts it away again.
    func toggleOnDemand() {
        if isPanelVisible {
            hidePanel()
            return
        }
        forceShow(announceEmpty: true)
    }

    /// Open the panel straight away, ignoring the idle timer.
    func forceShow(announceEmpty: Bool = false) {
        let found = pretendFleet ?? registry.refresh()
        guard !found.isEmpty else {
            NSLog("Fleet: no sessions to show")
            if announceEmpty { announceNoSessions() }
            return
        }
        sessions = found
        armed = false
        showPanel()
    }

    /// A manual trigger that silently does nothing reads as a broken app, so say why.
    private func announceNoSessions() {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No Claude Code sessions running"
        alert.informativeText = "Fleet shows a panel of your live sessions. "
            + "Start one in a terminal and open Fleet again."
        alert.alertStyle = .informational
        alert.runModal()
        // Same reason as `OverlayWindowController.hide`: hiding the app makes the next
        // activation warp the user to the Space we were hidden on.
        if let previous, !previous.isTerminated { previous.activate() } else { NSApp.deactivate() }
    }

    // MARK: - Timer

    private func schedule(_ interval: TimeInterval) {
        guard interval != currentInterval || timer == nil else { return }
        currentInterval = interval
        timer?.invalidate()

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Generous slack: we never need precise timing, and coalesced wakeups cost far less.
        t.tolerance = interval * Config.timerTolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !suspended, pretendFleet == nil else { return }

        if isPanelVisible {
            refreshVisible()
            return
        }

        // Cheapest possible gate: if no session is running, do nothing else at all.
        guard ProcessScanner.anyClaudeRunning() else {
            // Drop the last known fleet rather than leaving it stale. Nothing rendered it
            // before, but the menu bar shows the count continuously and would keep claiming
            // sessions that have since exited.
            if !sessions.isEmpty { sessions = [] }
            schedule(Config.idlePollDormant)
            return
        }
        schedule(Config.idlePollActive)

        // Refresh even while hidden, so what the panel shows is current the instant it opens
        // rather than as of whenever it last appeared. Transcripts are only re-read when their
        // size or mtime moved, so an idle fleet costs one `stat` per session.
        let found = registry.refresh()
        sessions = found

        let idle = IdleWatcher.idleSeconds()
        if idle < Config.idleThreshold {
            armed = true            // user is active; allow the next idle period to show
            return
        }
        guard armed, !found.isEmpty else { return }

        // Idle because you are watching something, not because you are done. Left armed on
        // purpose: when the video ends and the machine goes quiet for real, the next tick
        // shows the panel as usual. Only the *idle* trigger defers — the hotkey, the menu bar
        // and `fleet` all still open it mid-film, because those are you asking.
        if let reason = ScreenWatcher.holdingDisplayAwake() {
            NSLog("Fleet: not showing — something is holding the display awake (\(reason))")
            return
        }

        armed = false
        showPanel()
    }

    private func refreshVisible() {
        let found = registry.refresh()
        if found.isEmpty {
            hidePanel()          // last session exited while the panel was up
            return
        }
        sessions = found
    }

    // MARK: - Panel

    private func showPanel() {
        isPanelVisible = true
        // Two GETs, and only if the last pair is over a minute old. The columns draw whatever
        // they already have in the meantime rather than waiting on the network.
        hub.refreshIfStale()
        schedule(Config.visibleRefresh)
        overlay?.show()
    }

    /// Modifier keys, straight from the panel window — see `PanelWindow.sendEvent`. Nothing
    /// else observes them, so this is only ever ⌘ being pressed or let go.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.command)
        guard held != commandHeld else { return }
        commandHeld = held
    }

    func hidePanel() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        // A panel that comes back up with ⌘ still latched from last time would show its ✕s to
        // somebody who is not holding anything.
        commandHeld = false
        hub.stopComposing()
        overlay?.hide()
        schedule(Config.idlePollActive)
    }

    /// Return, while the panel is up: it belongs to the todo column's own field when the caret
    /// is in it. Returns whether it was used.
    func submitPrompt() -> Bool {
        guard isPanelVisible else { return false }
        return hub.commitDraft()
    }

    /// Esc, while the panel is up. The new-todo row first — backing out of a half-written todo
    /// should not also take the fleet off screen.
    func escape() {
        guard isPanelVisible else { return }
        if hub.stopComposing() { return }
        hidePanel()
    }

    /// ⌘ and a digit, while the panel is up: the same thing as clicking the tile wearing that
    /// number. Returns whether anything wore it, so an unclaimed number falls through to
    /// whatever else wants the key rather than being swallowed.
    func activate(number: Int) -> Bool {
        guard isPanelVisible, let session = sessions.first(where: { $0.number == number }) else {
            return false
        }
        activate(session)
        return true
    }

    /// Tile click: drop the panel, then raise the terminal running that session. Deliberately
    /// not `hidePanel()` — see `dismissForHandoff`.
    func activate(_ session: Session) {
        dismissForHandoff()
        TerminalFocus.focus(session: session)
    }

    /// The panel's `+`: a terminal, on a desktop of its own, gone to. Same handoff as a tile
    /// click — you end up on another desktop either way, so the panel goes first.
    ///
    /// The desktop is macOS's own doing: the window is sent fullscreen, and a fullscreen window
    /// is given a desktop and taken to it. No Space is created behind the Dock's back and
    /// nothing is clicked on its behalf — see `Spaces` for why that is the only route the
    /// window server actually honours.
    func newDesktop() {
        dismissForHandoff()
        TerminalLaunch.openTerminal(in: Config.projectRoot)
    }

    private func dismissForHandoff() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        overlay?.dismissForHandoff()
        schedule(Config.idlePollActive)
    }

    // MARK: - Sleep

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspended = true
                    self.timer?.invalidate()
                    self.timer = nil
                    self.currentInterval = 0
                    self.hidePanel()
                }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspended = false
                    self.armed = true
                    self.schedule(Config.idlePollDormant)
                }
            }
        }
    }
}

/// Whether something on screen is being watched rather than worked on.
///
/// Idle time alone cannot tell a finished day from a film: both are minutes without a
/// keystroke. The difference is that anything playing video asks macOS to keep the display
/// awake, so the assertion is the signal — and it is the app's own claim about what it is
/// doing, not a guess from process names or window titles.
///
/// Deliberately typed on *display* sleep and not system sleep: `caffeinate`, a long download
/// and a background build all keep the machine awake without anyone looking at it, and those
/// are exactly the moments the panel is welcome. Audio-only playback lands the same way — the
/// panel is silent, so a podcast is no reason to suppress it.
enum ScreenWatcher {

    private static let displayTypes: Set<String> = [
        kIOPMAssertionTypeNoDisplaySleep as String,             // "NoDisplaySleepAssertion"
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
    ]

    /// The assertion's own name when something is holding the display awake — Firefox calls
    /// its one "video-playing" — or nil when nothing is.
    static func holdingDisplayAwake() -> String? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return nil
        }
        for (_, assertions) in dict {
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      displayTypes.contains(type) else { continue }
                return assertion[kIOPMAssertionNameKey as String] as? String ?? type
            }
        }
        return nil
    }
}

/// Seconds since the last keyboard/mouse/trackpad event, straight from the HID event source.
enum IdleWatcher {
    private static let anyInput = CGEventType(rawValue: ~0)!

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
