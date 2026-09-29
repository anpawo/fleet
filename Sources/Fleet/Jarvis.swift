import AppKit
import Carbon.HIToolbox

/// One held Stop hook, as its `<sid>.ask` describes it. The protocol is
/// `~/.claude/councils/2026-09-28-jarvis-interventions/contract.md`.
struct JarvisAsk: Decodable {
    let sid: String
    let hookPid: pid_t
    let claudePid: pid_t
    let cwd: String
    var lastMessage: String?
    var at: Double?
    /// What to say instead of "<project> is done, sir.", for a composed line or a demo.
    var line: String?
    /// Shown without a voice, at once: to look at the panel.
    var silent: Bool?
}

/// Jarvis: when a session with a terminal ends its turn, the Stop hook holds and writes an
/// ask; a headless Claude reads the session and says what it did and what it should do next,
/// Fleet shows that one task, and writes it back as the hook's answer when taken. Switched
/// on, he first briefs Marius on every session.
@MainActor
final class Jarvis {
    private unowned let controller: AppController
    private let panel = JarvisPanel()

    private struct Item {
        let ask: JarvisAsk
        let project: String
        var line: String
        var task: String?
        /// The switch-on briefing: no hook behind it, nothing to answer.
        var briefing = false
        var key: String { "\(ask.sid):\(ask.hookPid)" }
    }

    private var queue: [Item] = []
    private var current: Item?
    /// Asks already taken, by sid and hook pid, for as long as their file exists: the hook
    /// removes it only after reading the answer, so the next scan would take it again.
    private var handled: Set<String> = []
    private var heartbeat: Timer?
    private var poll: Timer?
    private var watch: DispatchSourceFileSystemObject?
    private var nextShowAt = Date.distantPast

    private var shownAt = Date()
    private var live = false
    private var typing = false
    private var failed = false
    /// Input up to this instant is Jarvis's own: the keyboard before the panel showed, a digit
    /// it accepted, a click on the panel. Anything later is Marius working somewhere else.
    private var ignoreInputUntil = Date()

    private var voice: pid_t = 0
    private var voiceResult = "none"
    private var voiceEndedAt: Date?
    private var levels: FileHandle?
    private var levelsPath = ""
    private var levelBuffer = ""
    private var level = 0.0
    private var heardLevel = false
    private var waitingForVoice = false
    private var orbTimer: Timer?
    private var lastFrame = Date()

    private static let dir = Hooks.stateDirectory
    private static let onPath = (dir as NSString).appendingPathComponent("jarvis.on")
    private static let logPath = (Hooks.home as NSString).appendingPathComponent("jarvis-log.jsonl")
    private static let speakScript = NSHomeDirectory() + "/self/jarvis/tools/jarvis-speak.sh"
    private static let escID: UInt32 = 120

    init(controller: AppController) {
        self.controller = controller
        panel.model.act = { [weak self] action in self?.handle(action) }
    }

    /// Fleet's "never show itself" setting is about the panel, not about Jarvis: only his own
    /// switch silences him.
    private var active: Bool { controller.jarvisOn }

    func start() {
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let fd = open(Self.dir, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watch = source
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
        tick()
    }

    private func tick() {
        if active {
            if !FileManager.default.createFile(atPath: Self.onPath, contents: nil) {
                NSLog("Fleet: jarvis could not touch \(Self.onPath)")
            }
        } else {
            try? FileManager.default.removeItem(atPath: Self.onPath)
            releaseAll("off")
        }
        scan()
        queue.removeAll { item in
            guard !Self.alive(item.ask.hookPid) else { return false }
            NSLog("Fleet: jarvis withdrew \(item.project) (hook \(item.ask.hookPid) gone)")
            log(item, "withdrawn")
            return true
        }
        // Back from away, the Fleet panel shows every green tile: an item with no task is
        // redundant. A task, or the briefing, waits for the panel to go.
        if controller.isPanelVisible {
            queue.removeAll { item in
                guard item.task == nil, !item.briefing else { return false }
                release(item, "fleet panel")
                return true
            }
        }
        panel.model.queued = queue.count
        present()
    }

    // MARK: - Asks

    private func scan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.dir)) ?? []
        var seen: Set<String> = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for name in names where name.hasSuffix(".ask") {
            let path = (Self.dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let ask = try? decoder.decode(JarvisAsk.self, from: data) else { continue }
            let key = "\(ask.sid):\(ask.hookPid)"
            seen.insert(key)
            guard !handled.contains(key) else { continue }
            handled.insert(key)
            take(ask, path: path)
        }
        handled.formIntersection(seen)
    }

    private func take(_ ask: JarvisAsk, path: String) {
        // A hook killed hard leaves its ask behind; nothing will ever read an answer to it.
        guard Self.alive(ask.hookPid) else {
            try? FileManager.default.removeItem(atPath: path)
            NSLog("Fleet: jarvis dropped a stale ask for \(ask.sid) (hook \(ask.hookPid) gone)")
            return
        }
        let project = Session.project(for: ask.cwd)
        var item = Item(ask: ask, project: project,
                        line: ask.line ?? project.prefix(1).uppercased() + project.dropFirst() + " is done, sir.")
        NSLog("Fleet: jarvis picked up \(project) (\(ask.sid), hook \(ask.hookPid))")
        if let reason = releaseReason(for: ask) {
            release(item, reason)
            return
        }
        // A composed line or a demo is said as written.
        guard ask.line == nil else { return enqueue(item) }
        let message = ask.lastMessage.flatMap { $0.isEmpty ? nil : $0 } ?? session(for: ask)?.lastSaid ?? ""
        let steps = session(for: ask)?.steps ?? []
        let conversation = steps.map { step in
            (step.kind == .user ? "Marius: " : step.kind == .tool ? "Tool: " : "Claude: ") + step.text
        }.joined(separator: "\n") + "\nClaude (last message): " + message
        let todos = openTodos()
        Task { [weak self] in
            do {
                let next = try await Claude.nextTask(project: project, conversation: conversation, todos: todos)
                item.line = next.line
                item.task = next.task
            } catch {
                NSLog("Fleet: jarvis could not read \(project) — \(error)")
                item.task = JarvisOptions.nextStep(in: message)
            }
            guard let self, Self.alive(ask.hookPid) else { return }
            if let reason = self.releaseReason(for: ask) { return self.release(item, reason) }
            self.enqueue(item)
        }
    }

    private func enqueue(_ item: Item) {
        queue.append(item)
        panel.model.queued = queue.count
        present()
    }

    /// Marius's open todos, soonest first, with their day when they have one.
    private func openTodos() -> [String] {
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        return controller.hub.todos.filter(\.open)
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(15)
            .map { todo in todo.due.map { "\(todo.title) (due \(day.string(from: $0)))" } ?? todo.title }
    }

    /// Said once on switching on: every session, the ones waiting for a task first.
    func brief() {
        let sessions = controller.sessions.sorted { $0.state.sortRank < $1.state.sortRank }.map { s in
            let state = s.state == .ready ? "finished, waiting for a new task"
                : s.state == .awaitingAnswer ? "waiting on Marius" : "working"
            return [Session.project(for: s.cwd), state, s.transcript?.title ?? "",
                    String((s.lastSaid ?? "").prefix(400))].joined(separator: " · ")
        }
        let todos = openTodos()
        Task { [weak self] in
            do {
                let text = try await Claude.briefing(sessions: sessions, todos: todos)
                guard let self, self.active else { return }
                let ask = JarvisAsk(sid: "briefing", hookPid: getpid(), claudePid: 0, cwd: NSHomeDirectory())
                self.queue.insert(Item(ask: ask, project: "Fleet", line: text, briefing: true), at: 0)
                self.panel.model.queued = self.queue.count
                self.present()
            } catch {
                NSLog("Fleet: jarvis could not brief — \(error)")
            }
        }
    }

    /// Why this ask goes back empty at once, if it does.
    private func releaseReason(for ask: JarvisAsk) -> String? {
        if !active { return "off" }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "display asleep" }
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any],
           info["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
        // Fleet's own check: what holds the display awake is a presentation, a call's screen
        // share, or a film — never a moment to talk over.
        if let reason = ScreenWatcher.holdingDisplayAwake() { return "display held: \(reason)" }
        if controller.isPanelVisible { return "fleet panel" }
        if watching(ask) { return "watching" }
        return nil
    }

    /// The session Marius prompted last, in a terminal that is in front: he is looking at it.
    private func watching(_ ask: JarvisAsk) -> Bool {
        guard let lead = controller.lastPrompted, Self.matches(lead, ask),
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return Self.hostPID(ask.claudePid) == front
    }

    private func session(for ask: JarvisAsk) -> Session? {
        controller.sessions.first { Self.matches($0, ask) }
    }

    private static func matches(_ session: Session, _ ask: JarvisAsk) -> Bool {
        if session.id == ask.claudePid { return true }
        guard let path = session.transcript?.path else { return false }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension == ask.sid
    }

    private static func hostPID(_ pid: pid_t) -> pid_t? {
        ProcessScanner.hostApplication(of: pid)?.app.processIdentifier
    }

    private static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    // MARK: - On screen

    private func present() {
        guard current == nil, !queue.isEmpty, Date() >= nextShowAt, !controller.isPanelVisible else { return }
        // Away: no voice to an empty room. The hook keeps holding; the item shows on return.
        guard IdleWatcher.idleSeconds() < 60 else { return }
        let item = queue.removeFirst()
        guard Self.alive(item.ask.hookPid) else {
            log(item, "withdrawn")
            present()
            return
        }
        current = item
        shownAt = Date()
        typing = false
        failed = false
        voiceEndedAt = nil
        voiceResult = "none"
        let m = panel.model
        m.project = item.project
        m.line = item.line
        m.task = item.task
        m.briefing = item.briefing
        m.queued = queue.count
        m.failure = nil
        m.typing = false
        m.draft = ""
        live = false
        registerKeys()

        if let mic = MicWatcher.recording() {
            voiceResult = "mic: \(mic)"
            voiceEndedAt = Date()
            m.orb.set(.waiting)
            reveal()
        } else if item.ask.silent == true {
            voiceResult = "silent"
            voiceEndedAt = Date()
            m.orb.set(.waiting)
            reveal()
        } else {
            speak(item.line)
            waitingForVoice = true
        }

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// On screen once the voice is heard, not while the PC is still rendering it; without a
    /// voice, as soon as it has failed, and after 8 s at the latest.
    private func reveal() {
        guard let item = current else { return }
        waitingForVoice = false
        shownAt = Date()
        let startLive = Self.idle(.keyDown) >= 1.5 && !terminalOverBlueSession()
        setLive(startLive)
        panel.show()
        NSLog("Fleet: jarvis showing \(item.project) (\(startLive ? "live" : "passive"))")
    }

    /// A "1" typed at Claude Code's own question must reach it, not Jarvis.
    private func terminalOverBlueSession() -> Bool {
        guard controller.sessions.contains(where: { $0.state == .awaitingAnswer }),
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return controller.sessions.contains { Self.hostPID($0.proc.pid) == front }
    }

    /// 10 Hz while an item is on screen: the hook, the voice, the keyboard, the clock.
    private func check() {
        guard let item = current else { return }
        let now = Date()
        // While he types, the hook may go; the text is kept and lands on the clipboard.
        if !typing, !failed, !Self.alive(item.ask.hookPid) {
            NSLog("Fleet: jarvis withdrew \(item.project) (hook \(item.ask.hookPid) gone)")
            log(item, "withdrawn")
            dismiss()
            return
        }
        reapVoice()
        if waitingForVoice {
            guard heardLevel || voiceEndedAt != nil || now.timeIntervalSince(shownAt) > 8 else { return }
            reveal()
        }
        // A voice that never ends would hold the session forever: the timeout runs from its end.
        if voice > 0, now.timeIntervalSince(shownAt) > 30 { stopVoice() }
        if live, !typing {
            let idle = min(Self.idle(.keyDown), Self.idle(.leftMouseDown), Self.idle(.rightMouseDown))
            // 50 ms of slack: a digit Jarvis accepted reaches the HID clock before its hotkey
            // handler has had the chance to claim it.
            if now.addingTimeInterval(-idle) > ignoreInputUntil, idle > 0.05 { setLive(false) }
        }
        if !typing, let end = voiceEndedAt, now.timeIntervalSince(end) > (live && !failed ? 12 : 8) {
            if failed { dismiss() } else { finish("timeout", answer: "") }
        }
    }

    private static func idle(_ type: CGEventType) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
    }

    private func setLive(_ on: Bool) {
        live = on
        ignoreInputUntil = Date()
        panel.model.live = on
        registerKeys()
    }

    /// Bare keys are taken from the whole system, so only while Jarvis has the attention:
    /// LIVE, and none but Esc while typing. Tab takes the task, 0 opens the field. Return is
    /// never taken: it is the terminal's.
    private func registerKeys() {
        let keys = live && !typing && !failed
        let wanted = [(kVK_ANSI_0, keys && current?.briefing == false),
                      (kVK_Tab, keys && current?.task != nil)]
        for (k, (code, on)) in wanted.enumerated() {
            let id = UInt32(100 + k)
            guard on else { HotKey.unregister(id: id); continue }
            HotKey.register(Settings.Chord(keyCode: UInt16(code), modifiers: 0), id: id) { [weak self] in
                MainActor.assumeIsolated { self?.key(k) }
            }
        }
        if current != nil, live || typing || failed {
            HotKey.register(Settings.Chord(keyCode: UInt16(kVK_Escape), modifiers: 0), id: Self.escID) { [weak self] in
                MainActor.assumeIsolated { self?.escape() }
            }
        } else {
            HotKey.unregister(id: Self.escID)
        }
    }

    private func key(_ k: Int) {
        ignoreInputUntil = Date()
        k == 0 ? beginTyping() : take()
    }

    private func handle(_ action: JarvisPanel.Action) {
        guard current != nil else { return }
        switch action {
        case .take: take()
        case .type: beginTyping()
        case .submit(let text): submit(text)
        case .close: escape()
        case .rearm:
            ignoreInputUntil = Date().addingTimeInterval(0.1)
            if !live, !typing { setLive(true) }
        }
    }

    private func take() {
        guard let item = current, !failed, !typing, let task = item.task else { return }
        finish("take", answer: task)
    }

    private func beginTyping() {
        guard current?.briefing == false, !failed, !typing else { return }
        stopVoice()
        typing = true
        panel.model.typing = true
        registerKeys()
        panel.beginTyping()
    }

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typing, !text.isEmpty else { return }
        finish("type", answer: text)
    }

    /// One step back: out of the field to the task, else out of Jarvis.
    private func escape() {
        guard current != nil else { return }
        if typing {
            typing = false
            panel.model.typing = false
            panel.endTyping()
            voiceEndedAt = Date()
            setLive(true)
            return
        }
        if failed { dismiss(); return }
        finish("esc", answer: "")
        // A held or doubled Esc must not land in the terminal: there it cancels Claude.
        HotKey.register(Settings.Chord(keyCode: UInt16(kVK_Escape), modifiers: 0), id: Self.escID) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.current == nil else { return }
            HotKey.unregister(id: Self.escID)
        }
    }

    /// Ends the item with an answer for the hook. A non-empty answer that cannot reach the
    /// session stays on screen, says why, and goes to the clipboard.
    private func finish(_ outcome: String, answer: String) {
        guard let item = current else { return }
        stopVoice()
        let delivered = item.briefing || Self.alive(item.ask.hookPid) && write(answer, for: item.ask)
        if !delivered, !answer.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            log(item, outcome, detail: "not delivered")
            failed = true
            typing = false
            panel.model.typing = false
            panel.endTyping()
            panel.model.failure = "Didn't reach \(item.project): the session moved on. Your answer is on the clipboard."
            panel.relayout()
            voiceEndedAt = Date()
            registerKeys()
            return
        }
        log(item, outcome)
        dismiss()
    }

    private func dismiss() {
        stopVoice()
        current = nil
        waitingForVoice = false
        typing = false
        failed = false
        poll?.invalidate()
        poll = nil
        live = false
        registerKeys()
        panel.hide()
        nextShowAt = Date().addingTimeInterval(0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present() }
    }

    private func release(_ item: Item, _ reason: String) {
        if !item.briefing, Self.alive(item.ask.hookPid) { _ = write("", for: item.ask) }
        NSLog("Fleet: jarvis released \(item.project) empty (\(reason))")
        log(item, "released", detail: reason)
    }

    private func releaseAll(_ reason: String) {
        queue.forEach { release($0, reason) }
        queue = []
        if let item = current {
            release(item, reason)
            dismiss()
        }
    }

    private func write(_ answer: String, for ask: JarvisAsk) -> Bool {
        let url = URL(fileURLWithPath: (Self.dir as NSString).appendingPathComponent(ask.sid + ".answer"))
        do {
            try Data(answer.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Fleet: jarvis could not answer \(ask.sid) — \(error)")
            return false
        }
    }

    /// One line per intervention: the only way to learn he is being ignored before he says so.
    private func log(_ item: Item, _ outcome: String, detail: String? = nil) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "sid": item.ask.sid, "project": item.project, "task": item.task ?? "",
            "outcome": outcome,
        ]
        if let detail { entry["detail"] = detail }
        if current?.key == item.key {
            entry["live"] = live
            entry["voice"] = voiceResult
            entry["shown_ms"] = Int(Date().timeIntervalSince(shownAt) * 1000)
        }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let h = FileHandle(forWritingAtPath: Self.logPath) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: Self.logPath, contents: data)
        }
    }

    // MARK: - Voice

    /// `jarvis-speak.sh` in a process group of its own, so Esc takes the whole pipeline down
    /// with one signal and the script can resume the music on its way out.
    private func speak(_ line: String) {
        levelsPath = NSTemporaryDirectory() + "jarvis-levels-\(getpid()).log"
        FileManager.default.createFile(atPath: levelsPath, contents: nil)
        levels = FileHandle(forReadingAtPath: levelsPath)
        levelBuffer = ""
        level = 0
        heardLevel = false

        var env = ProcessInfo.processInfo.environment
        // launchd hands Fleet a bare PATH; the script needs ffmpeg, jq and media-control.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["JARVIS_LEVELS"] = levelsPath
        let argv: [UnsafeMutablePointer<CChar>?] = ([Self.speakScript, line] as [String]).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var files = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&files)
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&files)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, Self.speakScript, &files, &attr, argv, envp)
        guard rc == 0 else {
            NSLog("Fleet: jarvis could not start the voice (\(rc))")
            voiceResult = "spawn failed"
            voiceEndedAt = Date()
            panel.model.orb.set(.silent)
            return
        }
        voice = pid
        voiceResult = "speaking"
        panel.model.orb.set(.preparing)
        lastFrame = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(t, forMode: .common)
        orbTimer = t
    }

    /// The orb, one frame: the last RMS the player reported, smoothed with a fast attack and a
    /// slower release so it follows syllables without flickering.
    private func frame() {
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        lastFrame = now
        if let data = levels?.availableData, !data.isEmpty {
            levelBuffer += String(decoding: data, as: UTF8.self)
            var lines = levelBuffer.components(separatedBy: "\n")
            levelBuffer = lines.removeLast()
            let marker = "lavfi.astats.Overall.RMS_level="
            if let last = lines.last(where: { $0.contains(marker) }),
               let db = Double(last.components(separatedBy: marker)[1].trimmingCharacters(in: .whitespaces)) {
                heardLevel = true
                levelTarget = db.isFinite ? min(max((db + 50) / 40, 0), 1) : 0
            }
        }
        let tau = levelTarget > level ? 0.04 : 0.15
        level += (levelTarget - level) * (1 - exp(-dt / tau))
        panel.model.orb.frame(level: level, speaking: heardLevel)
    }
    private var levelTarget = 0.0

    private func reapVoice() {
        guard voice > 0 else { return }
        var status: Int32 = 0
        guard waitpid(voice, &status, WNOHANG) == voice else { return }
        voice = 0
        let exited = status & 0x7f == 0
        let code = (status >> 8) & 0xff
        voiceEnded()
        // 2: the script could render nothing — PC off, server down. The panel stays as is.
        if exited && code == 2 {
            voiceResult = "no voice"
            panel.model.orb.set(.silent)
        } else {
            voiceResult = exited && code == 0 ? "spoken" : "failed \(code)"
        }
    }

    private func stopVoice() {
        guard voice > 0 else { return }
        let pid = voice
        voice = 0
        kill(-pid, SIGTERM)
        DispatchQueue.global().async { waitpid(pid, nil, 0) }
        voiceResult = "stopped"
        voiceEnded()
    }

    private func voiceEnded() {
        orbTimer?.invalidate()
        orbTimer = nil
        try? levels?.close()
        levels = nil
        try? FileManager.default.removeItem(atPath: levelsPath)
        levelTarget = 0
        voiceEndedAt = Date()
        panel.model.orb.set(.waiting)
    }
}

// MARK: - Options

/// The fallback when the session cannot be read: its own "⟶" next step, if it named one.
enum JarvisOptions {
    /// The last "⟶" line, unless it is also the first: that one is the answer, not a step.
    static func nextStep(in message: String) -> String? {
        let lines = message.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let i = lines.lastIndex(where: { $0.hasPrefix("⟶") }), i > 0 else { return nil }
        let text = lines[i].dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func check(_ expect: (String?, String?, String) -> Void) {
        expect(nextStep(in: """
            ⟶ Les corporate actions ne sont pas perdues.

            - `ca_close.py` a tourné à 02:14

            ⟶ Relance `./recon.sh --date 2026-09-27` pour vérifier.
            """), "Relance `./recon.sh --date 2026-09-27` pour vérifier.",
               "jarvis: the last ⟶ line is the step")
        expect(nextStep(in: "⟶ Yes, the hook is version 13."), nil,
               "jarvis: a lone ⟶ line is the answer, not a step")
    }
}
