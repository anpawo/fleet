import Foundation

/// Tunables. Kept in one place so the whole battery profile is auditable at a glance.
enum Config {
    /// How long the user must be idle before the panel appears.
    static var idleThreshold: TimeInterval = 150      // 2.5 min

    /// Poll cadence when at least one Claude Code session is alive.
    static let idlePollActive: TimeInterval = 15
    /// Poll cadence when no session is alive (pure "is anything running yet" check).
    static let idlePollDormant: TimeInterval = 60
    /// Refresh cadence while the panel is on screen.
    static let visibleRefresh: TimeInterval = 3

    /// Timer slack, as a fraction of the interval. Large tolerance lets macOS coalesce
    /// our wakeups with other timers instead of waking the CPU on its own.
    static let timerTolerance: Double = 0.5

    /// A pending tool older than this, with no CPU burn, is treated as "blocked on you"
    /// rather than "still working".
    static let pendingStaleAfter: TimeInterval = 12
    /// Sustained CPU above this means the session is genuinely working.
    static let busyCPUPercent: Double = 3.0

    /// Only the tail of a transcript is parsed; sessions are long and we only need recent state.
    static let transcriptTailBytes: Int = 256 * 1024
    /// Conversation lines kept for the tile preview.
    static let previewLineCount: Int = 14
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
    var tty: String?          // e.g. "/dev/ttys003"; nil when not attached to a terminal
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

    /// Last path component of the working directory, e.g. "portfolio".
    var dirName: String {
        let n = (proc.cwd as NSString).lastPathComponent
        return n.isEmpty ? proc.cwd : n
    }

    /// Working directory with $HOME collapsed to "~".
    var displayPath: String {
        let home = NSHomeDirectory()
        if proc.cwd == home { return "~" }
        if proc.cwd.hasPrefix(home + "/") { return "~" + proc.cwd.dropFirst(home.count) }
        return proc.cwd
    }

    var topic: String {
        if let t = transcript?.title, !t.isEmpty { return t }
        if let p = transcript?.lastPrompt, !p.isEmpty { return p }
        return "New session"
    }
}
