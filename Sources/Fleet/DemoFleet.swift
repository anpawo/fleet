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
        let states: [SessionState] = [.ready, .running, .delegated, .awaitingAnswer, .apiError, .paused]

        return (0 ..< count).map { i in
            let state = states[i % states.count]
            let name = names[i % names.count]
            let proc = ClaudeProcess(pid: pid_t(90000 + i), ppid: 1,
                                     cwd: "/Users/\(NSUserName())/self/\(name)",
                                     tty: "/dev/ttys0\(i)", startedAt: Date().addingTimeInterval(-3600), cpuNanos: 0)

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
            // And the delegated one too: its two pills side by side are the widest header.
            if i % 3 == 1 || state == .delegated {
                info.pendingTaskIDs = ["task-\(i)"]
                info.pendingToolNames = ["Task"]
                info.subagents = [SubagentRun(id: "a\(i)", kind: "Explore",
                                              task: "Audit the palette",
                                              step: "Grep contrast-ratio",
                                              lastActivity: Date())]
            }
            if state == .delegated {
                info.backgroundShellsStartedAt = [Date().addingTimeInterval(-22 * 60)]
            }

            return Session(proc: proc, transcript: info, state: state,
                           cpuPercent: state == .running ? 4 : 0)
        }
    }

    /// The side columns filled with nothing of this machine's, as `sessions` does the grid.
    /// The mail, the todos, the school and the bank's export are their owner's: a picture
    /// meant to be published — the README's — is drawn with `--fake` for that reason.
    @MainActor
    static func fill(_ controller: AppController) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func text(_ value: String) -> [String: Any] { ["stringValue": value] }
        func stamp(_ days: Double) -> [String: Any] {
            ["timestampValue": iso.string(from: now.addingTimeInterval(days * 86_400))]
        }
        func document(_ name: String, _ fields: [String: [String: Any]]) -> Firestore.Document {
            let json = try! JSONSerialization.data(withJSONObject: ["name": name, "fields": fields])
            return try! JSONDecoder().decode(Firestore.Document.self, from: json)
        }

        let mail = [("Invoice for the March sprint", "Ada Quill", -0.2),
                    ("Your talk is accepted", "Lantern Conf", -1),
                    ("Renewal notice for orchard.dev", "Harbour Domains", -3)]
            .enumerated().compactMap { index, mail in
                Mail(document("mail/\(index)", ["gist": text(mail.0), "sender": text(mail.1),
                                                "receivedAt": stamp(mail.2)]))
            }
        let todos = [("Renew the domain", 2.0 as Double?), ("Reply to the sprint review", nil),
                     ("Book the train to Lyon", nil), ("Clean up the staging bucket", nil)]
            .enumerated().map { index, todo in
                var fields = ["name": text(todo.0), "state": text(Todo.Pile.todo),
                              "createdAt": stamp(-Double(index + 1))]
                if let due = todo.1 { fields["dueAt"] = stamp(due) }
                return Todo(document("todos/\(index)", fields))
            }

        let folder = FileManager.default.temporaryDirectory.appending(path: "fleet-demo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let school: [String: Any] = [
            "generatedAt": iso.string(from: now), "sessionOk": true,
            "errors": [String](), "deadlines": [String](),
            "registrations": [("G-ALG-500", "G5 - Algorithms", 5), ("G-NET-500", "G5 - Networks", 3),
                              ("G-CMP-500", "G5 - Compilers", 7)].map {
                ["code": $0.0, "instance": "DEM-1", "name": $0.1, "credits": $0.2,
                 "start": iso.string(from: now.addingTimeInterval(-60 * 86_400)),
                 "end": iso.string(from: now.addingTimeInterval(45 * 86_400))] as [String: Any]
            },
        ]
        try? JSONSerialization.data(withJSONObject: school).write(to: folder.appending(path: "state.json"))

        // This month and the one before, so SPENDING has its heading and something to set it against.
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        let spent = [("Groceries & bakeries", 310.0), ("\"Restaurants, fast food & coffee\"", 140),
                     ("Train", 85), ("Leisure & sport", 70), ("Clothes", 60),
                     ("Subscriptions & apps", 45), ("Health", 20)]
        let lines = [0, -1].flatMap { back in
            let id = month.string(from: Calendar.current.date(byAdding: .month, value: back, to: now) ?? now)
            return spent.map { "\(id)-05,-\($0.1 - Double(back) * 15),\($0.0),demo" }
        }
        try? (["date,amount,category,merchant"] + lines).joined(separator: "\n")
            .write(to: folder.appending(path: "payments.csv"), atomically: true, encoding: .utf8)

        controller.hub.pretend(mail: mail, todos: todos, school: folder.appending(path: "state.json"))
        controller.money.file = folder.appending(path: "payments.csv")
    }
}
