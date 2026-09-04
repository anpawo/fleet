import AppKit
import Combine
import CoreAudio
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
            statusItem?.update(ram: reaper.footprint, muted: muteRemaining != nil)
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

    /// Frees memory before the machine starts swapping itself to a standstill, and names what
    /// it will not touch. See `Reaper` for the rule it applies.
    let reaper = Reaper()

    private let registry = SessionRegistry()
    private let notifier = Notifier()
    private var overlay: OverlayWindowController?
    private var controlCenter: ControlCenterController?
    private var statusItem: StatusItemController?
    private var timer: Timer?
    /// When the reaper last walked the process table — see `tick`.
    private var lastReap = Date.distantPast
    private var currentInterval: TimeInterval = 0
    private var suspended = false

    /// Guards against the panel reappearing the instant it is dismissed. Re-arms only once
    /// the user has been active again.
    private var armed = true

    /// While this is in the future, the panel never opens on its own. The chord, the menu bar
    /// and `fleet` all still work — muting is about Fleet interrupting you, not about locking
    /// it away.
    @Published private(set) var mutedUntil: Date?

    func start() {
        overlay = OverlayWindowController(controller: self)
        statusItem = StatusItemController(controller: self)
        bindHotKeys()
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
        // A kill is silent by nature — you would otherwise find out that Docker had quit by
        // discovering it was not there. One banner per reap, saying what went and how much
        // that gave back.
        reaper.onReaped = { [weak self] summary in
            self?.notifier.announce(title: "Fleet freed some memory", body: summary)
        }
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

    /// The settings window, behind a right-click on the menu bar plane. Built on first use —
    /// most launches never open it.
    func showControlCenter() {
        let center = controlCenter ?? ControlCenterController(controller: self)
        controlCenter = center
        center.show()
    }

    /// The two global chords, as currently set. Called again when the menu changes one, which
    /// releases the old chord and claims the new one.
    func bindHotKeys() {
        // A toggle, because Esc is not always yours to spend: the panel goes up over a
        // terminal, and Esc there belongs to whatever is running in it. The chord that raised
        // the panel is the one hand already knows, so it is also the one that puts it away.
        HotKey.register(Settings.panelChord, id: 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPanelVisible { self.hidePanel() }
                else { self.forceShow(announceEmpty: true) }
            }
        }
        HotKey.register(Settings.muteChord, id: 2) { [weak self] in
            MainActor.assumeIsolated { self?.toggleMute() }
        }
    }

    // MARK: - Mute

    /// How much longer Fleet stays quiet, or nil when it isn't muted.
    var muteRemaining: TimeInterval? {
        guard let mutedUntil else { return nil }
        let left = mutedUntil.timeIntervalSinceNow
        return left > 0 ? left : nil
    }

    /// The mute chord. Muting also puts the panel away if it happens to be up — you press this
    /// because Fleet is in your way, and "in your way" usually means it is on screen right now.
    /// Pressed again while muted, it unmutes: the same key gets you out of it.
    func toggleMute() {
        if muteRemaining != nil {
            mutedUntil = nil
        } else {
            mutedUntil = Date().addingTimeInterval(Settings.muteDuration)
            if isPanelVisible { hidePanel() }
        }
        statusItem?.update(ram: reaper.footprint, muted: muteRemaining != nil)
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

        // Ahead of the dormant gate below on purpose: memory fills up whether or not any
        // session is running, and the machine this is protecting is the whole machine.
        //
        // Not on every tick, though. A visible panel ticks once a second and the reaper walks
        // the whole process table, which is 24 ms of main thread it does not need to spend on
        // a problem that takes days to build up — and 24 ms once a second is a stutter in
        // whatever you are scrolling.
        if Date().timeIntervalSince(lastReap) >= Config.reapInterval {
            lastReap = Date()
            reaper.tick()
            // The dot in the menu bar is this number, and a session list that never changes —
            // a dormant machine — would otherwise leave it on whatever it was at launch.
            statusItem?.update(ram: reaper.footprint, muted: muteRemaining != nil)
        }

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
        if idle < Settings.idleThreshold {
            armed = true            // user is active; allow the next idle period to show
            return
        }
        guard armed, !found.isEmpty else { return }

        // Checked here rather than earlier so the refresh above still runs while muted: the
        // panel you then open by hand has to be current.
        guard muteRemaining == nil else { return }

        // Idle because you are watching something, not because you are done. Left armed on
        // purpose: when the video ends and the machine goes quiet for real, the next tick
        // shows the panel as usual. Only the *idle* trigger defers — the hotkey, the menu bar
        // and `fleet` all still open it mid-film, because those are you asking.
        if let reason = ScreenWatcher.holdingDisplayAwake() {
            NSLog("Fleet: not showing — something is holding the display awake (\(reason))")
            return
        }

        // Idle because you are talking — a dictation tool, a call. Same deal as the film:
        // left armed, so the next quiet tick after you stop shows the panel as usual.
        if let device = MicWatcher.recording() {
            NSLog("Fleet: not showing — \(device) is recording")
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

/// Whether a microphone is recording right now.
///
/// The other half of the "idle but busy" problem. `ScreenWatcher` covers being read to;
/// this covers talking — dictating into Handy, or a call with the camera off. Neither
/// touches the keyboard, so the idle timer counts them as an empty desk, and the panel
/// would open in the middle of a sentence you are still speaking.
///
/// CoreAudio answers directly: every device carries `IsRunningSomewhere`, which is true while
/// any process on the machine has IO running on it. Asked per device rather than of the
/// default input alone, because a dictation tool may be pointed at the built-in mic while the
/// default input is a headset — and asked on the *input* scope, so a combo device (AirPods, a
/// USB interface) playing sound out does not read as recording.
enum MicWatcher {

    /// The name of a device that is recording, or nil when nothing is.
    static func recording() -> String? {
        for device in devices() where hasInput(device) && isRunning(device) {
            return name(device) ?? "microphone"
        }
        return nil
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0,
                                         nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Devices with no input channels are speakers, and speakers are never recording.
    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func name(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
