import Foundation

/// Joins live processes to their transcripts and derives each session's state.
@MainActor
final class SessionRegistry {

    private let store = TranscriptStore()
    /// Previous CPU sample per pid, for computing CPU% between refreshes.
    private var cpuSamples: [pid_t: (nanos: UInt64, at: Date)] = [:]
    /// Sticky pid -> transcript bindings, so a session keeps its file once identified.
    private var bindings: [pid_t: String] = [:]
    /// Throttle for the cross-project rescue scan — see `rescueUnbound`.
    private var lastWideScan = Date.distantPast
    private let screens = TerminalWatch()
    /// pid -> the number its tile wears. See `assignNumbers`.
    private var numbers: [pid_t: Int] = [:]

    func refresh() -> [Session] {
        let procs = ProcessScanner.scan()
        let now = Date()

        // Drop bookkeeping for processes that exited.
        let live = Set(procs.map(\.pid))
        cpuSamples = cpuSamples.filter { live.contains($0.key) }
        bindings = bindings.filter { live.contains($0.key) }
        screens.forget(everythingBut: live)
        numbers = numbers.filter { live.contains($0.key) }
        assignNumbers(procs)

        bind(procs)
        store.retain(paths: Set(bindings.values))

        var sessions: [Session] = []
        for proc in procs {
            let cpu = cpuPercent(for: proc, now: now)
            let info = bindings[proc.pid].flatMap { store.info(for: $0) }
            // A bound transcript that yields nothing is worth saying out loud: downstream it is
            // indistinguishable from a session that has never been prompted, so it degrades a
            // tile silently rather than failing.
            if info == nil, let bound = bindings[proc.pid] {
                NSLog("Fleet: no transcript info for pid \(proc.pid) from \(bound)")
            }
            // "Waiting for you" is the one verdict worth a second opinion, because it is the
            // only one reached purely by inference — from silence, which is also what a failed
            // request and a long thinking turn look like. Nothing else is re-examined; the
            // terminal costs a round trip to read.
            var state = state(for: bindings[proc.pid], info: info, cpu: cpu, now: now)
            if state == .awaitingAnswer {
                switch screens.verdict(proc, now: now) {
                case .retrying: state = .apiError
                case .working: state = .running
                case .unknown: break
                }
            }
            sessions.append(Session(
                number: numbers[proc.pid] ?? 0,
                proc: proc,
                transcript: info,
                state: state,
                cpuPercent: cpu
            ))
        }

        // Ready first — see `SessionState.sortRank` — then stable by pid so tiles don't shuffle.
        return sessions.sorted {
            $0.state.sortRank != $1.state.sortRank
                ? $0.state.sortRank < $1.state.sortRank
                : $0.proc.pid < $1.proc.pid
        }
    }

    /// Give every new session the lowest number nobody is using.
    ///
    /// Lowest free rather than ever-increasing, because the number is meant to be said out loud
    /// and pointed at — six sessions should be one to six, not thirty-one to thirty-six because
    /// of everything that ran this morning. A number is a session's for as long as it lives and
    /// goes back in the pot the moment it exits.
    ///
    /// Handed out oldest first, so on a cold start the numbers follow the order the sessions
    /// were actually started in rather than whatever order the process table came back in.
    private func assignNumbers(_ procs: [ClaudeProcess]) {
        for proc in procs.sorted(by: { $0.startedAt < $1.startedAt })
        where numbers[proc.pid] == nil {
            let taken = Set(numbers.values)
            var free = 1
            while taken.contains(free) { free += 1 }
            numbers[proc.pid] = free
        }
    }

    // MARK: - Process to transcript binding

    /// Several sessions frequently share one working directory, so the directory alone can't
    /// identify a transcript. Resolution runs in three passes, most reliable first.
    private func bind(_ procs: [ClaudeProcess]) {
        // Told, not guessed — and not second-guessed either: these are left alone below, since
        // a hook-named file need not even live in the directory the process reports.
        let told = bindFromHooks(procs)

        // Group by working directory — transcripts are stored per directory.
        var byDir: [String: [ClaudeProcess]] = [:]
        for p in procs { byDir[p.cwd, default: []].append(p) }

        for (cwd, group) in byDir {
            let files = TranscriptStore.transcripts(for: cwd)
            guard !files.isEmpty else { continue }

            var claimed = Set(bindings.filter { live($0.key, in: group) }.map(\.value))
            var unresolved: [ClaudeProcess] = []

            for proc in group where !told.contains(proc.pid) {
                // Already bound and still valid.
                if let existing = bindings[proc.pid],
                   files.contains(where: { $0.path == existing }) {
                    continue
                }

                // Pass 1: `claude --resume <id>` names its transcript outright.
                if let id = resumeID(for: proc.pid),
                   let match = files.first(where: { $0.sessionID == id }),
                   !claimed.contains(match.path) {
                    bindings[proc.pid] = match.path
                    claimed.insert(match.path)
                    continue
                }
                unresolved.append(proc)
            }

            // Pass 2: a fresh session writes its transcript shortly after launch, so bind each
            // process to a transcript created just after it started.
            //
            // Matched globally on the smallest gap, not greedily in launch order. The file is
            // created on the *first prompt*, not at launch, and that ordering does not have to
            // follow the launch ordering: start A, start B, prompt B, prompt A, and walking the
            // processes oldest-first hands A the file B just created — the two tiles in that
            // directory then swap conversations, and clicking one raises the other's terminal.
            // Scoring every pair and taking the closest first is immune to that ordering.
            var scored: [(pid: pid_t, path: String, gap: TimeInterval)] = []
            for proc in unresolved {
                for file in files where !claimed.contains(file.path)
                    && file.birth >= proc.proc_startMinusGrace {
                    scored.append((proc.pid, file.path,
                                   file.birth.timeIntervalSince(proc.startedAt)))
                }
            }
            // Tie-broken on pid then path, so the assignment never depends on scan order.
            scored.sort {
                if $0.gap != $1.gap { return $0.gap < $1.gap }
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return $0.path < $1.path
            }

            var matched = Set<pid_t>()
            for pair in scored
            where !matched.contains(pair.pid) && !claimed.contains(pair.path) {
                bindings[pair.pid] = pair.path
                claimed.insert(pair.path)
                matched.insert(pair.pid)
            }

            // Pass 3: `--continue` reopens an older transcript — created before the process, so
            // pass 2 never considers it. Fall back to the most recently active unclaimed file.
            for proc in unresolved.sorted(by: { $0.startedAt < $1.startedAt })
            where !matched.contains(proc.pid) {
                if let fallback = files.first(where: { !claimed.contains($0.path) }),
                   fallback.mtime > proc.startedAt {
                    bindings[proc.pid] = fallback.path
                    claimed.insert(fallback.path)
                }
                // Otherwise: a session that has not been prompted yet, so it has no
                // transcript. It renders as a ready tile with just its directory.
            }
        }

        rescueUnbound(procs)
    }

    /// Pass 0: the pairing the hooks name outright, which outranks every guess below.
    ///
    /// Every other pass infers the pairing from where a process is and when its file appeared,
    /// and then keeps it, because a session's transcript does not normally move. It does move:
    /// `/clear` and a compaction both start a new file in the same process. The binding then
    /// points at a conversation that ended, and a finished conversation reads as a finished
    /// session — the tile goes green and stays green while the session works, which is the one
    /// failure the colour is supposed to prevent.
    ///
    /// A hook fires inside the session, is handed the file it is writing, and runs as a child
    /// of the session itself — so between the payload and its own ancestry it knows both halves
    /// of the pairing. The hook process is long gone by the time Fleet reads the record, but the
    /// pid it names is the session's, and that one is still there.
    @discardableResult
    private func bindFromHooks(_ procs: [ClaudeProcess]) -> Set<pid_t> {
        let live = Set(procs.map(\.pid))
        var newest: [pid_t: (path: String, at: Date)] = [:]
        for (_, record) in Hooks.records() {
            guard let path = record.transcriptPath,
                  let pid = record.pids.first(where: { live.contains($0) }),
                  FileManager.default.fileExists(atPath: path) else { continue }
            if let current = newest[pid], current.at >= record.at { continue }
            newest[pid] = (path, record.at)
        }
        guard !newest.isEmpty else { return [] }

        var bound: Set<pid_t> = []
        for proc in procs {
            guard let match = newest[proc.pid],
                  // A record older than the process itself came from whatever held this pid
                  // before — the session it names is not this one.
                  match.at >= proc.proc_startMinusGrace else { continue }
            // The file can only belong to one session, and it now belongs to this one.
            for (pid, path) in bindings where path == match.path && pid != proc.pid {
                bindings[pid] = nil
            }
            if bindings[proc.pid] != match.path {
                NSLog("Fleet: hooks bind pid \(proc.pid) -> \(match.path)")
            }
            bindings[proc.pid] = match.path
            bound.insert(proc.pid)
        }
        return bound
    }

    /// Pass 4, for sessions whose transcript is not filed under their working directory at all.
    ///
    /// Claude Code picks the project folder once, from the directory the session started in, and
    /// keeps writing there for the rest of the session. Rename that directory — or `cd` out of
    /// it — and the process now reports a cwd that maps to a different folder, usually an empty
    /// one, so every pass above finds nothing and the session shows up as a tile with no history
    /// and a green border whatever it is doing.
    ///
    /// The transcript itself is not lost: every entry stamps the session's *current* directory,
    /// so the file that keeps naming this process's cwd is the file that belongs to it.
    private func rescueUnbound(_ procs: [ClaudeProcess]) {
        let unbound = procs.filter { bindings[$0.pid] == nil }
        guard !unbound.isEmpty else { return }

        // A session that has simply never been prompted is also unbound, and stays that way, so
        // this must not turn into a directory walk on every refresh.
        let now = Date()
        guard now.timeIntervalSince(lastWideScan) >= Config.rescueScanInterval else { return }
        lastWideScan = now

        let candidates = TranscriptStore.recentTranscripts(within: Config.rescueScanWindow)
        guard !candidates.isEmpty else { return }
        var claimed = Set(bindings.values)

        for proc in unbound {
            let match = candidates.first { file in
                !claimed.contains(file.path) && store.info(for: file.path)?.cwd == proc.cwd
            }
            guard let match else { continue }
            bindings[proc.pid] = match.path
            claimed.insert(match.path)
            NSLog("Fleet: rescued pid \(proc.pid) (\(proc.cwd)) -> \(match.path)")
        }
    }

    private func live(_ pid: pid_t, in group: [ClaudeProcess]) -> Bool {
        group.contains { $0.pid == pid }
    }

    private func resumeID(for pid: pid_t) -> String? {
        let args = ProcessScanner.arguments(pid)
        guard let idx = args.firstIndex(where: { $0 == "--resume" || $0 == "-r" }),
              idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        return value.hasPrefix("-") ? nil : value
    }

    // MARK: - State derivation

    private func cpuPercent(for proc: ClaudeProcess, now: Date) -> Double {
        defer { cpuSamples[proc.pid] = (proc.cpuNanos, now) }
        guard let previous = cpuSamples[proc.pid] else { return 0 }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.2, proc.cpuNanos >= previous.nanos else { return 0 }
        let burned = Double(proc.cpuNanos - previous.nanos) / 1_000_000_000
        return burned / elapsed * 100
    }

    /// What a session is doing, from the hooks when they have spoken and from the transcript
    /// when they have not.
    ///
    /// The two sources are ranked by recency, and the hook wins a tie. A hook fires *on* the
    /// transition, so it is the better evidence for as long as nothing has happened since —
    /// which is exactly the case the transcript reads wrong. Once the transcript moves again
    /// after the last hook event, the file is the newer news and the inference takes over: the
    /// hooks may not be installed at all, may have been installed after this session started,
    /// or may have missed an event, and none of those should freeze a tile on a stale colour.
    ///
    /// The two-second grace is for the writes that trail a hook by a moment — Claude Code
    /// stamps `ai-title` and `last-prompt` into the file just after a turn ends, and those must
    /// not count as the session getting back to work.
    private func state(for transcriptPath: String?, info: TranscriptInfo?,
                       cpu: Double, now: Date) -> SessionState {
        let heuristic = derivedState(info: info, cpu: cpu, now: now)
        guard let transcriptPath else { return heuristic }
        let sessionID = ((transcriptPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        guard let hook = Hooks.record(sessionID: sessionID) else { return heuristic }
        if let said = info?.lastWord, said > hook.at.addingTimeInterval(2) { return heuristic }

        // A `running` hook is the better evidence right up until the turn it announced dies
        // without ever reaching `Stop`. A request that errors out — a usage limit, a dropped
        // connection — writes nothing to the transcript and fires no closing hook, so the red
        // it left behind stays for as long as the session lives, on a session sitting idle at
        // its prompt. Nothing pending, nothing written, no CPU, for minutes: that is not work,
        // it is a hook whose other half never came, and the transcript is the better reader of
        // what the session is actually owed.
        if hook.state == .running,
           !(info?.hasPendingTool ?? false),
           cpu < Config.busyCPUPercent,
           now.timeIntervalSince(hook.at) >= Config.runningHookStaleAfter {
            return heuristic
        }
        return hook.state
    }

    /// Red / green / blue, from the transcript tail plus CPU.
    ///
    /// A pending tool call means Claude asked to do something and no result came back. That is
    /// either work in progress or a prompt sitting on screen waiting for you — the transcript
    /// looks identical in both cases, so the tie is broken on whether the session is actually
    /// burning CPU or writing to its transcript.
    private func derivedState(info: TranscriptInfo?, cpu: Double, now: Date) -> SessionState {
        guard let info else {
            // No transcript to read: either a session that has never been prompted, or one whose
            // file we could not find. Green is the right guess for the first and a lie for the
            // second, so let sustained CPU speak for a session we otherwise know nothing about.
            return cpu >= Config.busyCPUPercent ? .running : .ready
        }

        guard info.hasPendingTool else {
            // Nothing pending, but the last word was yours — a prompt Claude has not started
            // answering, or a tool result it has not responded to yet. Identical to a finished
            // turn in the transcript, and the opposite of ready.
            if info.turnOpen {
                // …with one exception, and it is the case this whole branch gets wrong most
                // often: a multiple-choice question waiting on the screen.
                //
                // `AskUserQuestion` is not in the transcript while it is pending. Claude Code
                // holds that assistant message back and flushes it only once the question has
                // been answered — the entry then lands carrying the timestamp it was generated
                // at, which is why it *looks* like it was there all along when you read the
                // file afterwards. Live, there is nothing to match on: the last thing written
                // is the tool result from the step before, and the session sits there owing a
                // turn it has already delivered to the terminal.
                //
                // What that leaves is the silence. A model that is genuinely still working
                // writes a block every few seconds and burns CPU rendering it; a question on
                // the screen does neither. So an owed turn that has gone quiet on both counts
                // is read as waiting for you.
                if cpu < Config.busyCPUPercent,
                   now.timeIntervalSince(info.lastWord) >= Config.silentTurnStaleAfter {
                    return .awaitingAnswer
                }
                return .running
            }
            // Turn finished cleanly: waiting for a new prompt.
            return .ready
        }

        // Tools that exist purely to ask the user something are unambiguous. Only reachable
        // once the answer has been given — kept because `ExitPlanMode` does show up pending,
        // and because a flushed `AskUserQuestion` costs nothing to keep matching.
        let asking: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
        if info.pendingToolNames.contains(where: { asking.contains($0) }) {
            return .awaitingAnswer
        }

        // A sub-agent writes to its own transcript, not this one, and burns its tokens on
        // Anthropic's machines rather than this CPU. So a session waiting on one goes quiet on
        // every signal below, trips the stale-pending test, and claims to need you — while the
        // truth is that it is busy and there is nothing for you to do. The sub-agent's own file
        // is the missing signal.
        if info.subagents.contains(where: {
            now.timeIntervalSince($0.lastActivity) < Config.pendingStaleAfter
        }) {
            return .running
        }

        if cpu >= Config.busyCPUPercent { return .running }

        let quietFor = now.timeIntervalSince(info.lastWord)
        if quietFor < Config.pendingStaleAfter { return .running }

        // Stale, silent, and a tool is outstanding. In bypass mode nothing can block on
        // approval, so it is a long-running command rather than a prompt.
        if info.permissionMode == "bypassPermissions" { return .running }
        return .awaitingAnswer
    }
}

private extension ClaudeProcess {
    /// Transcripts are created moments after launch; allow a little slack for clock jitter.
    var proc_startMinusGrace: Date { startedAt.addingTimeInterval(-5) }
}

/// A second opinion on a session that looks like it is waiting for you, taken from the one
/// place the truth is actually written down: its terminal.
///
/// Two things are invisible everywhere else. A failed request prints "API error · Retrying in
/// 4s · attempt 3/10" and writes no transcript entry, no hook and burns no CPU. A long turn —
/// a big thinking block, a slow stream — prints "Slithering… (9m 59s · ↓ 4.8k tokens)" and,
/// until the message lands, writes nothing either. Both leave a transcript that is silent with
/// a turn still owed, which is exactly the signature of a question sitting on the screen.
///
/// Reading costs a Scripting Bridge round trip on the main thread, so the answer is cached, and
/// cached for much longer once it comes back inconclusive: a session on a genuine question sits
/// there for an hour, and asking its terminal every four seconds throughout is a lot of round
/// trips to re-learn the same thing.
@MainActor
final class TerminalWatch {
    enum Verdict {
        /// Stuck retrying a request that failed.
        case retrying
        /// Claude Code's spinner is up: the model is working, it is just not writing yet.
        case working
        /// Nothing on the screen contradicts the guess — including a terminal we cannot read
        /// at all, which is not evidence of anything.
        case unknown
    }

    private var seen: [pid_t: (at: Date, verdict: Verdict)] = [:]

    func verdict(_ proc: ClaudeProcess, now: Date) -> Verdict {
        if let last = seen[proc.pid] {
            let interval = last.verdict == .unknown ? Config.terminalRecheckInterval
                                                    : Config.terminalReadInterval
            if now.timeIntervalSince(last.at) < interval { return last.verdict }
        }
        let verdict = TerminalFocus.visibleText(pid: proc.pid, tty: proc.tty)
            .map(Self.read) ?? .unknown
        seen[proc.pid] = (now, verdict)
        if verdict != .unknown {
            NSLog("Fleet: pid \(proc.pid) screen says \(verdict), not waiting on you")
        }
        return verdict
    }

    func forget(everythingBut live: Set<pid_t>) {
        seen = seen.filter { live.contains($0.key) }
    }

    /// The last few lines only, and that limit is the whole trick. Claude Code pins its status
    /// to the bottom of the screen, so both signals are always within a handful of lines of the
    /// prompt — while the scrollback above is a conversation that may well be *about* API
    /// errors, in which case a whole-screen search finds the words and reports a session in
    /// perfect health as broken.
    static func read(_ screen: String) -> Verdict {
        let tail = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
            .lowercased()

        // Checked first: a retry is also a turn in flight, and the spinner keeps running
        // through it — so the more specific reading has to win.
        if tail.contains("retrying in")
            || tail.contains("hit your session limit")
            || tail.contains("usage limit reached")
            || (tail.contains("api error") && tail.contains("attempt")) {
            return .retrying
        }

        // The spinner line, which is the elapsed time and the token counter: "(9m 59s · ↓ 4.8k
        // tokens)". Matched on the counter rather than the word in front of it — that word is
        // a different one every time, by design.
        if tail.contains("esc to interrupt")
            || (tail.contains("tokens)") && (tail.contains("\u{2193}") || tail.contains("\u{2191}"))) {
            return .working
        }
        return .unknown
    }
}
