import Foundation

/// Synthetic sessions, for looking at the panel at sizes you do not happen to have running.
///
/// The grid changes shape with the count — two columns, then three, then it pages sideways —
/// and those rules are otherwise only checkable by starting nine terminals. Used by
/// `--render --fake <n>`; nothing reaches this in normal operation.
enum DemoFleet {

    static func sessions(_ count: Int) -> [Session] {
        let names = ["portfolio", "atlas", "video-code", "my-hub", "fleet", "siege",
                     "orchard", "lantern", "harbour", "quarry", "meridian", "tessera"]
        let states: [SessionState] = [.ready, .running, .awaitingAnswer, .apiError]

        return (0 ..< count).map { i in
            let state = states[i % states.count]
            let name = names[i % names.count]
            let proc = ClaudeProcess(pid: pid_t(90000 + i), ppid: 1,
                                     cwd: "/Users/\(NSUserName())/self/\(name)",
                                     tty: "/dev/ttys0\(i)", startedAt: Date(), cpuNanos: 0)

            var info = TranscriptInfo(
                path: "/tmp/\(name).jsonl",
                title: "Work on \(name)",
                lastPrompt: nil,
                permissionMode: nil,
                hasPendingTool: state != .ready,
                pendingToolNames: state == .ready ? [] : ["Bash"],
                pendingToolLabels: state == .ready ? [] : ["Bash npm test"],
                pendingTaskIDs: [],
                lastCompletedTool: "Read",
                cwd: "/Users/\(NSUserName())/self/\(name)",
                turnOpen: state == .running,
                lastActivity: Date(),
                preview: [
                    PreviewLine(kind: .user, text: "Fix the thing in \(name)"),
                    PreviewLine(kind: .tool, text: "Read \(name).swift"),
                    PreviewLine(kind: .assistant, text: "Found it — one line, in the parser."),
                ])

            // Every third one has delegated, so the orange line is on screen too.
            if i % 3 == 1 {
                info.pendingTaskIDs = ["task-\(i)"]
                info.pendingToolNames = ["Task"]
                info.subagents = [SubagentRun(id: "a\(i)", kind: "Explore",
                                              task: "Audit the palette",
                                              step: "Grep contrast-ratio",
                                              lastActivity: Date())]
            }

            return Session(number: i + 1, proc: proc, transcript: info, state: state,
                           cpuPercent: state == .running ? 4 : 0)
        }
    }
}
