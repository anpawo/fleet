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
                state: derivedState(info: info, cpu: cpu, now: now),
                cpuPercent: cpu
            ))
        }

        // Sessions needing attention first; then stable by pid so tiles don't shuffle.
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
            // process to the unclaimed transcript created soonest *after* it started.
            for proc in unresolved.sorted(by: { $0.startedAt < $1.startedAt }) {
                let candidate = files
                    .filter { !claimed.contains($0.path) }
                    .filter { $0.birth >= proc.proc_startMinusGrace }
                    .min { $0.birth < $1.birth }

                if let match = candidate {
                    bindings[proc.pid] = match.path
                    claimed.insert(match.path)
                    continue
                }

                // Pass 3: `--continue` reopens an older transcript, so fall back to the most
                // recently active unclaimed file.
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
            if info.turnOpen { return .running }
            // Turn finished cleanly: waiting for a new prompt.
            return .ready
        }

        // Tools that exist purely to ask the user something are unambiguous.
        let asking: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
        if info.pendingToolNames.contains(where: { asking.contains($0) }) {
            return .awaitingAnswer
        }

        if cpu >= Config.busyCPUPercent { return .running }

        let quietFor = now.timeIntervalSince(info.lastActivity)
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
