import Foundation

/// `fleet --selftest`. The pieces of this app whose rules only ever meet at runtime — whether a
/// sub-agent is still working, which sessions are ghosts — read from files written by something
/// else, so checked against files rather than mocks.
@MainActor
enum SelfCheck {

    static func run() -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want)\n        got  \(got)")
                failures += 1
            }
        }

        subagents(expect)
        ghosts(expect)

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    // MARK: - Sub-agents

    /// A transcript with an agent launched into the background, written the way Claude Code
    /// writes one: the call is answered at once, the agent's own file lives in a sibling
    /// directory, and the only thing that ever says it finished is a `<task-notification>`
    /// arriving turns later.
    private static func subagents(_ expect: (Int, Int, String) -> Void) {
        let root = NSTemporaryDirectory() + "fleet-selftest-\(getpid())"
        let session = root + "/session.jsonl"
        let agents = root + "/session/subagents"
        try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let call = "toolu_selftest"
        func stamp(_ secondsAgo: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
        }
        func append(_ line: String) {
            let data = Data((line + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: session) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: session))
            }
            // The store skips a file whose size and mtime have not moved, and a test that
            // writes twice in the same millisecond would read its own stale cache.
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: session)
        }

        try? #"{"agentType":"general-purpose","description":"Audit the palette","toolUseId":"\#(call)"}"#
            .write(toFile: agents + "/agent-x.meta.json", atomically: true, encoding: .utf8)
        try? #"""
        {"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(30))","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_inner","name":"Grep","input":{"pattern":"contrast"}}]}}
        """#.write(toFile: agents + "/agent-x.jsonl", atomically: true, encoding: .utf8)

        append(#"{"type":"user","timestamp":"\#(stamp(120))","cwd":"/tmp","message":{"content":[{"type":"text","text":"audit the palette"}]}}"#)
        append(#"{"type":"assistant","timestamp":"\#(stamp(119))","message":{"id":"m2","content":[{"type":"tool_use","id":"\#(call)","name":"Agent","input":{"description":"Audit the palette"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(118))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(call)","content":[{"type":"text","text":"Async agent launched successfully."}]}]}}"#)
        append(#"{"type":"assistant","timestamp":"\#(stamp(117))","message":{"id":"m3","content":[{"type":"text","text":"Started it."}]}}"#)

        let store = TranscriptStore()
        let launched = store.info(for: session)
        expect(launched?.unfinishedAgentIDs.count ?? -1, 1,
               "an answered Agent call is still an agent out")
        expect(launched?.subagents.count ?? -1, 1,
               "and its own transcript is found and read")
        expect(launched?.hasPendingTool == true ? 1 : 0, 0,
               "with nothing pending on the main thread")

        append(#"{"type":"user","timestamp":"\#(stamp(5))","message":{"content":[{"type":"text","text":"<task-notification>\n<tool-use-id>\#(call)</tool-use-id>\n<status>completed</status>\n</task-notification>"}]}}"#)

        let done = store.info(for: session)
        expect(done?.unfinishedAgentIDs.count ?? -1, 0,
               "a task-notification ends it")
        expect(done?.subagents.count ?? -1, 0,
               "and the tile stops counting it")

        // A shell moved to the background and then stopped by hand: no notification follows.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m4","content":[{"type":"tool_use","id":"toolu_sh","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh","content":"Command did not complete within its 120s timeout and was moved to the background (ID: b1x2y3z). Output is being written to: /tmp/x"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell moved to the background is a shell out")
        append(#"{"type":"assistant","timestamp":"\#(stamp(2))","message":{"id":"m5","content":[{"type":"tool_use","id":"toolu_stop","name":"TaskStop","input":{"task_id":"b1x2y3z"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(1))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_stop","content":"{\"message\":\"Successfully stopped task: b1x2y3z (sleep 99)\",\"task_id\":\"b1x2y3z\"}"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and TaskStop ends it")
    }

    // MARK: - Ghosts

    /// Two real processes, told apart only by the `CLAUDE_PID` they were started with: one names
    /// a pid nothing holds, the other names this process, which is alive and started first.
    private static func ghosts(_ expect: (Bool, Bool, String) -> Void) {
        var dead: pid_t = 99_000
        while kill(dead, 0) == 0 { dead += 1 }
        func spawn(owner: pid_t) -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["30"]
            p.environment = ["CLAUDE_PID": String(owner)]
            try? p.run()
            return p
        }
        let orphan = spawn(owner: dead), child = spawn(owner: getpid())
        defer { orphan.terminate(); child.terminate() }
        usleep(200_000)

        let found = Dictionary(uniqueKeysWithValues: Reaper.candidates().map { ($0.pid, $0.kind) })
        expect(found[orphan.processIdentifier] == .ghost, true, "ghosts: a tool process is a candidate")
        expect(Reaper.ownerGone(orphan.processIdentifier), true, "its session gone, it is a ghost")
        expect(Reaper.ownerGone(child.processIdentifier), false, "its session alive, it is left alone")
    }
}
