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

    func refresh() -> [Session] {
        let procs = ProcessScanner.scan()
        let now = Date()

        // Drop bookkeeping for processes that exited.
        let live = Set(procs.map(\.pid))
        cpuSamples = cpuSamples.filter { live.contains($0.key) }
        bindings = bindings.filter { live.contains($0.key) }

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
            sessions.append(Session(
                proc: proc,
                transcript: info,
                state: state(for: bindings[proc.pid], info: info, cpu: cpu, now: now),
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

    // MARK: - Process to transcript binding

    /// Several sessions frequently share one working directory, so the directory alone can't
    /// identify a transcript. Resolution runs in three passes, most reliable first.
    private func bind(_ procs: [ClaudeProcess]) {
        // Group by working directory — transcripts are stored per directory.
        var byDir: [String: [ClaudeProcess]] = [:]
        for p in procs { byDir[p.cwd, default: []].append(p) }

        for (cwd, group) in byDir {
            let files = TranscriptStore.transcripts(for: cwd)
            guard !files.isEmpty else { continue }

            var claimed = Set(bindings.filter { live($0.key, in: group) }.map(\.value))
            var unresolved: [ClaudeProcess] = []

            for proc in group {
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
