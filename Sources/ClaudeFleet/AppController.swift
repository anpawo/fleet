import AppKit
import Combine

/// Drives the whole app: watches for idle, decides when the panel appears, and keeps the
/// wakeup cadence as low as the current situation allows.
///
/// Battery profile, cheapest state first:
///   • no sessions   — one `proc_listpids` every 60s, nothing else
///   • sessions live — plus an idle check every 15s (a single in-process call)
///   • panel visible — transcripts re-read every 3s, and only tails that changed
/// The timer carries a 50% tolerance so macOS coalesces these wakeups with other timers
/// rather than waking the CPU just for us, and everything stops entirely on sleep.
@MainActor
final class AppController: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var isPanelVisible = false

    private let registry = SessionRegistry()
    private var overlay: OverlayWindowController?
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var suspended = false

    /// Guards against the panel reappearing the instant it is dismissed. Re-arms only once
    /// the user has been active again.
    private var armed = true

    func start() {
        overlay = OverlayWindowController(controller: self)
        observeSleepWake()
        schedule(Config.idlePollDormant)
        tick()
    }

    /// `--render`: populate the panel without any window, for offscreen image rendering.
    func injectSessions(_ found: [Session]) {
        sessions = found
    }

    /// `--demo`: open the panel straight away, ignoring the idle timer.
    func forceShow() {
        let found = registry.refresh()
        guard !found.isEmpty else {
            NSLog("ClaudeFleet: no sessions to show")
            return
        }
        sessions = found
        armed = false
        showPanel()
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
        guard !suspended else { return }

        if isPanelVisible {
            refreshVisible()
            return
        }

        // Cheapest possible gate: if no session is running, do nothing else at all.
        guard ProcessScanner.anyClaudeRunning() else {
            schedule(Config.idlePollDormant)
            return
        }
        schedule(Config.idlePollActive)

        let idle = IdleWatcher.idleSeconds()
        if idle < Config.idleThreshold {
            armed = true            // user is active; allow the next idle period to show
            return
        }
        guard armed else { return }

        // Only now do we pay for transcript parsing.
        let found = registry.refresh()
        guard !found.isEmpty else { return }

        sessions = found
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
        schedule(Config.visibleRefresh)
        overlay?.show()
    }

    func hidePanel() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        overlay?.hide()
        schedule(Config.idlePollActive)
    }

    /// Tile click: dismiss, then raise the terminal running that session.
    func activate(_ session: Session) {
        hidePanel()
        TerminalFocus.focus(session: session)
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

/// Seconds since the last keyboard/mouse/trackpad event, straight from the HID event source.
enum IdleWatcher {
    private static let anyInput = CGEventType(rawValue: ~0)!

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
