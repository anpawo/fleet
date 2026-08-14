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

    /// How long an owed-but-silent turn is given before it is read as a question on the screen
    /// rather than a model still writing. Longer than `pendingStaleAfter`, because there is no
    /// pending tool call corroborating it: the only evidence is the silence itself, and a long
    /// thinking block streams for a while before it lands in the file.
    static let silentTurnStaleAfter: TimeInterval = 25

    /// How often the cross-project hunt for a session's transcript may run, and how recently a
    /// transcript must have been written to be a candidate. Only ever runs while some session is
    /// unbound; the window is what keeps it to a handful of files.
    static let rescueScanInterval: TimeInterval = 5
    static let rescueScanWindow: TimeInterval = 300

    /// Only the tail of a transcript is parsed; sessions are long and we only need recent state.
    static let transcriptTailBytes: Int = 256 * 1024
    /// How many live sub-agents a session will read and report. A council run spawns half a
    /// dozen at once; past this the tile only counts them, so parsing more buys nothing.
    static let maxLiveSubagents: Int = 8
    /// Conversation lines kept for the tile preview.
    static let previewLineCount: Int = 14
    /// Of those, how many a tile actually draws.
    static let railLineCount: Int = 3

    /// Where the prompt field looks for projects, and where new ones are created.
    static var projectRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("self")
    }
    /// Whether a session Fleet starts gets a desktop to itself.
    ///
    /// Not a Space created from scratch — macOS exposes no public API for that, and the
    /// private route costs a partly disabled SIP. This is a *native fullscreen* window, which
    /// macOS puts on its own desktop and switches to. The property that makes it the better
    /// trade: closing the window disposes of the desktop with it, so asking a question never
    /// leaves an empty bureau behind.
    ///
    /// Off means the session opens as an ordinary window on the desktop you are already on.
    ///
    /// Only applies to sessions Fleet starts itself, which own their window. Clicking a tile
    /// deliberately does *not* do this: it takes you to the session's window wherever it
    /// already is, rather than rearranging your desktops around it. A terminal window carries
    /// all of its tabs with it, so making one session fullscreen would drag its neighbours onto
    /// a new desktop too.
    static let openInOwnDesktop = true

    /// Your language, for the model prompts: it tells the router which language to write
    /// prompts and answers in.
    ///
    /// Nothing here touches transcription. Fleet has no microphone and no dictation of its
    /// own — the field takes text, whether you type it or a dictation tool pastes it in.
    static let language = "French"
}

/// What a session is doing right now, which drives the tile border colour.
enum SessionState {
    case running        // red   — a tool is in flight
    case ready          // green — finished its turn, waiting for a new prompt
    case awaitingAnswer // blue  — blocked on a question or a permission approval

    /// What comes first in the panel. Ready leads: those are the sessions you can pick up and
    /// type into right now, which is what you open the panel to do. A session blocked on a
    /// question is next — it needs you, but answering it is a smaller thing than starting the
    /// next piece of work. One that is working needs nothing from you at all, so it comes last.
    var sortRank: Int {
        switch self {
        case .ready: return 0
        case .awaitingAnswer: return 1
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

/// A sub-agent the session spawned with `Task` and has not heard back from.
///
/// Worth surfacing on its own because it is the one case where a session looks idle and is not:
/// the sub-agent writes to its own transcript, so the main file goes silent, the CPU goes quiet,
/// and every signal Fleet reads says "nothing happening" while a whole agent works in the
/// background. The main thread cannot do anything until it reports back.
struct SubagentRun: Identifiable {
    /// Claude Code's own agent id, which names the file it writes to.
    var id: String
    /// The agent type it was spawned as — "Explore", "general-purpose", …
    var kind: String
    /// The one-line description the `Task` call gave it.
    var task: String
    /// What the sub-agent is doing right now, read from its own transcript.
    var step: String?
    /// Last write to the sub-agent's transcript — how we know it is still alive.
    var lastActivity: Date

    /// Who is working, in the fewest words that still identify it. The task description is
    /// specific to this run and the type is generic, so the description wins when there is one.
    var label: String { task.isEmpty ? kind : task }
}

/// Everything parsed out of a session's transcript file.
struct TranscriptInfo {
    var path: String
    var title: String?        // Claude Code's own "ai-title"
    var lastPrompt: String?
    var permissionMode: String?
    var hasPendingTool: Bool
    /// Tools in flight, most recently started first.
    var pendingToolNames: [String]
    /// The same tools with their argument — "Bash npm test" rather than "Bash". Same order.
    var pendingToolLabels: [String]
    /// `tool_use` ids of the pending `Task` calls, which is what ties a running sub-agent's
    /// file back to the call waiting on it.
    var pendingTaskIDs: [String]
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
    /// Last write to the file, whatever it was.
    var lastActivity: Date
    /// When the last thing was actually *said* — see `ParseState.lastMessageAt`. Nil for a
    /// transcript whose entries carry no stamp, which is what the fallback to `lastActivity`
    /// below is for.
    var lastMessageAt: Date?

    /// How recently this session did something, as everything reading it means the question:
    /// the last conversation entry, or the file itself when there is no stamp to go on.
    var lastWord: Date { lastMessageAt ?? lastActivity }
    var preview: [PreviewLine]
    /// Sub-agents spawned and not yet finished. Filled in after the parse — it needs the
    /// sub-agents' own files, which the main transcript only points at.
    var subagents: [SubagentRun] = []
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
        // A pending `Task` is drawn by the sub-agent line instead: "Task" names the mechanism,
        // that line names who is working and what they are doing.
        let names = (transcript?.pendingToolNames ?? [])
            .filter { $0 != "Task" || subagents.isEmpty }
        guard !names.isEmpty else {
            // Nothing of its own in flight. Either it is composing a reply, or every tool out
            // is a sub-agent and the line below already says so.
            return subagents.isEmpty ? "thinking…" : nil
        }
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    /// Sub-agents working for this session right now.
    var subagents: [SubagentRun] { transcript?.subagents ?? [] }

    /// What the sub-agents are up to, as the one line a tile has room for: who is working, and
    /// what they are doing this second. Nil when nothing is delegated.
    var subagentLine: String? {
        guard let first = subagents.first else { return nil }
        let who = subagents.count == 1
            ? first.label
            : "\(subagents.count) sub-agents · \(first.label)"
        guard let step = first.step, !step.isEmpty else { return who }
        return "\(who) · \(step)"
    }

    /// The last thing Claude said, for a notification body — the question it is waiting on is
    /// usually the sentence right before it asked.
    var lastSaid: String? {
        steps.last { $0.kind == .assistant }?.text
    }

    /// The recent conversation, oldest first: your prompts, the tools Claude ran, what it said.
    var steps: [PreviewLine] { transcript?.preview ?? [] }
}
