import AppKit
import Darwin

/// Terminal windows that were opened and never used, and the terminal apps left standing
/// behind them.
///
/// Where they come from: Ghostty runs one app process per window here, and it keeps running
/// once its last surface closes — the macOS convention, an app with no window is still an app.
/// A session that ends by closing its own surface (`/ck` kills claude, the shell exits, the
/// surface goes) therefore leaves a process with nothing in it. Nothing on screen shows it:
/// with no window it is in no ⌘-Tab list. Click its icon in the Dock and macOS asks it to
/// open a window, and it makes a fresh one on a bare prompt — the blank terminals.
///
/// So there are two things to sweep, and the second is the cause of the first: a shell nobody
/// ever typed in, and a terminal app with no shell under it at all.
enum EmptyTerminals {

    /// The shells a terminal starts. `login` is deliberately not here: it is the parent of the
    /// shell, never the leaf, and killing it would leave the shell orphaned rather than close
    /// the window.
    private static let shells: Set<String> = ["fish", "zsh", "bash", "sh", "dash", "ksh", "tcsh"]

    /// How long a window has to have sat untouched, and how much use it is allowed to have
    /// seen, before it counts as never used.
    ///
    /// A tty's mtime is its last read or write — the figure `w` prints as IDLE. A shell whose
    /// tty has not moved since its own prompt was drawn is a window in which nothing was ever
    /// typed and nothing was ever printed, which is the only kind safe to close: a window
    /// holding the output of something you ran is a window with something in it, however long
    /// ago you ran it.
    private static let idleBefore: TimeInterval = 300
    private static let neverUsed: TimeInterval = 90

    /// An app has to have been up this long before its emptiness means anything — a terminal
    /// that has just launched has no shell yet for a second or two.
    private static let settled: TimeInterval = 300

    private static let period: TimeInterval = 300
    private nonisolated(unsafe) static var lastSweep = Date.distantPast

    /// Off with `defaults write com.mr.fleet sweepEmptyTerminals -bool false`.
    static func sweepIfDue(now: Date = Date()) {
        guard UserDefaults.standard.object(forKey: "sweepEmptyTerminals") as? Bool ?? true,
              now.timeIntervalSince(lastSweep) > period else { return }
        lastSweep = now
        for line in sweep(now: now) { NSLog("Fleet: closed an empty terminal — \(line)") }
    }

    /// What is empty, and — unless `dryRun` — closing it. One line per thing closed.
    @discardableResult
    static func sweep(now: Date = Date(), dryRun: Bool = false) -> [String] {
        let pids = ProcessScanner.allPIDs()
        var parent: [pid_t: pid_t] = [:]
        var hasChildren: Set<pid_t> = []
        for pid in pids {
            let up = parentOf(pid)
            parent[pid] = up
            if up > 0 { hasChildren.insert(up) }
        }

        // Every app with a shell somewhere under it. Marked before anything is closed, so an
        // app whose only shell is hung up in this very sweep still counts as busy and is left
        // for the next one — five minutes later, and only if it really is empty by then.
        var serving: Set<pid_t> = []
        for pid in pids where ProcessScanner.controllingTTY(pid) != nil {
            var current = pid
            for _ in 0..<12 {
                guard let up = parent[current], up > 1 else { break }
                serving.insert(up)
                current = up
            }
        }

        var closed: [String] = []

        for pid in pids where !hasChildren.contains(pid) {
            guard let tty = ProcessScanner.controllingTTY(pid),
                  let info = ProcessScanner.bsdInfo(pid) else { continue }
            let name = (ProcessScanner.executablePath(pid) as NSString).lastPathComponent
            guard shells.contains(name), terminal(above: pid, parent: parent) != nil,
                  let touched = lastTouched(tty) else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
            guard now.timeIntervalSince(touched) > idleBefore,
                  touched.timeIntervalSince(started) < neverUsed else { continue }
            closed.append("\(name) \(pid) on \(tty), nothing ever typed in it, "
                          + "idle \(Int(now.timeIntervalSince(touched)) / 60)m")
            // The shell, not the window: Ghostty closes a surface whose shell has gone, and
            // there is no window to ask — see `~/.claude/memory/tools/ghostty.md`.
            if !dryRun { kill(pid, SIGHUP) }
        }

        for pid in pids where !serving.contains(pid) {
            let path = ProcessScanner.executablePath(pid)
            // Ghostty alone. Terminal.app keeps a window open on "[Process completed]", which
            // is a window with something in it; quitting it would throw that away.
            guard path.contains("/Ghostty.app/"), let info = ProcessScanner.bsdInfo(pid),
                  info.pbi_ppid == 1 else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
            guard now.timeIntervalSince(started) > settled else { continue }
            closed.append("ghostty \(pid), no shell under it, up "
                          + "\(Int(now.timeIntervalSince(started)) / 3600)h")
            // Asked to quit, not killed: it is an app, and it has state of its own to write.
            if !dryRun { kill(pid, SIGTERM) }
        }

        return closed
    }

    /// The terminal app this shell is running in, if it is running in one at all — a shell
    /// under `sshd`, or under a test harness, is nobody's window to close.
    private static func terminal(above pid: pid_t, parent: [pid_t: pid_t]) -> pid_t? {
        var current = pid
        for _ in 0..<8 {
            guard let up = parent[current], up > 1 else { return nil }
            let path = ProcessScanner.executablePath(up)
            if path.contains("/Ghostty.app/") || path.contains("/Terminal.app/")
                || path.contains("/iTerm.app/") { return up }
            current = up
        }
        return nil
    }

    /// The parent of any process, including one that is not ours.
    ///
    /// `ProcessScanner.parent` asks for the full BSD info, which the kernel refuses for a
    /// process belonging to another user — and `login`, which sits between the terminal and
    /// the shell, is root's. The short form is public to everyone, and the chain from a shell
    /// up to the window it lives in runs straight through that one root process.
    private static func parentOf(_ pid: pid_t) -> pid_t {
        var short = proc_bsdshortinfo()
        let size = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short,
                                Int32(MemoryLayout<proc_bsdshortinfo>.size))
        return size > 0 ? pid_t(short.pbsi_ppid) : 0
    }

    /// The last time anything was read from or written to this terminal.
    private static func lastTouched(_ tty: String) -> Date? {
        var info = stat()
        guard stat(tty, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}
