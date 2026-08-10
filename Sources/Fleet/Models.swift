import Foundation

/// Tunables. Kept in one place so the whole battery profile is auditable at a glance.
enum Config {
    /// How long the user must be idle before the panel appears.
    static var idleThreshold: TimeInterval = 45

    /// Full-refresh cadence when at least one session is alive but the panel is hidden. Fleet
    /// keeps its picture current in the background so the panel is never a moment out of date
    /// when it appears — a stale first frame is worse than the wakeups cost.
    static let idlePollActive: TimeInterval = 5
    /// Poll cadence when no session is alive (pure "is anything running yet" check).
    static let idlePollDormant: TimeInterval = 60
    /// Refresh cadence while the panel is on screen.
    static let visibleRefresh: TimeInterval = 1

    /// Timer slack, as a fraction of the interval. Large tolerance lets macOS coalesce
    /// our wakeups with other timers instead of waking the CPU on its own.
    static let timerTolerance: Double = 0.5

    /// A pending tool older than this, with no CPU burn, is treated as "blocked on you"
    /// rather than "still working".
    static let pendingStaleAfter: TimeInterval = 12
    /// Sustained CPU above this means the session is genuinely working.
    static let busyCPUPercent: Double = 3.0

    /// How often the cross-project hunt for a session's transcript may run, and how recently a
    /// transcript must have been written to be a candidate. Only ever runs while some session is
    /// unbound; the window is what keeps it to a handful of files.
    static let rescueScanInterval: TimeInterval = 5
    static let rescueScanWindow: TimeInterval = 300

    /// Only the tail of a transcript is parsed; sessions are long and we only need recent state.
    static let transcriptTailBytes: Int = 256 * 1024
    /// Conversation lines kept for the tile preview.
    static let previewLineCount: Int = 14
    /// Of those, how many a tile actually draws.
    static let railLineCount: Int = 3
}

/// What a session is doing right now, which drives the tile border colour.
enum SessionState {
    case running        // red   — a tool is in flight
    case ready          // green — finished its turn, waiting for a new prompt
    case awaitingAnswer // blue  — blocked on a question or a permission approval

    var sortRank: Int {
        switch self {
        case .awaitingAnswer: return 0   // needs you most — surface first
        case .ready: return 1
        case .running: return 2
        }
    }
}

/// A live `claude` process discovered on this machine.
struct ClaudeProcess {
    var pid: pid_t
    var ppid: pid_t
    var cwd: String
    var tty: String           // e.g. "/dev/ttys003"; always present — see ProcessScanner
    var startedAt: Date
    var cpuNanos: UInt64      // cumulative user+system time, for delta-based CPU%
}

/// Everything parsed out of a session's transcript file.
struct TranscriptInfo {
    var path: String
    var title: String?        // Claude Code's own "ai-title"
    var lastPrompt: String?
    var permissionMode: String?
    var hasPendingTool: Bool
    var pendingToolNames: [String]
    /// Name of the most recent tool that actually finished — the last completed step. Nil
    /// when nothing in the parsed tail ran to completion.
    var lastCompletedTool: String?
    /// The session's own working directory, which diverges from the process cwd as soon as
    /// anything `cd`s. This is what the session's status line shows.
    var cwd: String?
    /// The last thing on the main thread came from your side — your prompt, or a result handed
    /// back to a tool call — so Claude still owes a reply. No tool is pending, but the turn is
    /// very much not over.
    var turnOpen: Bool
    var lastActivity: Date
    var preview: [PreviewLine]
}

/// One rendered line of the mini-transcript shown on a tile.
struct PreviewLine: Identifiable {
    enum Kind { case user, assistant, tool }
    let id = UUID()
    var kind: Kind
    var text: String
}

/// A process joined with its transcript — the unit the UI renders.
struct Session: Identifiable {
    var id: pid_t { proc.pid }
    var proc: ClaudeProcess
    var transcript: TranscriptInfo?
    var state: SessionState
    var cpuPercent: Double

    /// Where the session is working *now*. The process cwd is only where it was launched:
    /// `cd` inside a session moves the session but never the process, so a tile keyed on the
    /// process would keep naming a directory the session left long ago. Transcripts record the
    /// live value, so prefer it and fall back to the process for a session too new to have one.
    var cwd: String { transcript?.cwd ?? proc.cwd }

    /// Last path component of the working directory, e.g. "portfolio".
    var dirName: String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty ? cwd : n
    }

    /// Working directory with $HOME collapsed to "~".
    var displayPath: String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    var topic: String {
        if let t = transcript?.title, !t.isEmpty { return t }
        if let p = transcript?.lastPrompt, !p.isEmpty { return p }
        return "New session"
    }

    /// Path to show beneath the name, or nil when it only repeats the name — the usual case
    /// for a project checked out at ~/self/<name>. The name alone already identifies those.
    var subPath: String? {
        let path = displayPath
        return (path as NSString).lastPathComponent == dirName ? nil : path
    }

    /// The step in flight right now, pinned under the history. Nil unless the session is
    /// working — the rail already shows everything that has finished.
    var currentStep: String? {
        guard state == .running else { return nil }
        let names = transcript?.pendingToolNames ?? []
        // Working with no tool out means it is composing a reply rather than doing something.
        guard !names.isEmpty else { return "thinking…" }
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    /// The recent conversation, oldest first: your prompts, the tools Claude ran, what it said.
    var steps: [PreviewLine] { transcript?.preview ?? [] }
}
