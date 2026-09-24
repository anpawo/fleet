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
        ports(expect)

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    // MARK: - Listening ports

    /// Where a KeepAlive job answers is read out of `lsof`, and the one rule that is not
    /// obvious is which port wins when a process holds several: the lowest, not the first
    /// printed. `lsof` prints in file-descriptor order, so tailscaled's SOCKS proxy came
    /// after whatever it had dialled out on.
    private static func ports(_ expect: (Int, Int, String) -> Void) {
        let captured = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Python    52741   mr    3u  IPv4 0x1a2b3c4d5e6f7080      0t0  TCP 127.0.0.1:8766 (LISTEN)
        Python    52802   mr    3u  IPv4 0x1a2b3c4d5e6f7081      0t0  TCP 127.0.0.1:8767 (LISTEN)
        Python    52860   mr    4u  IPv4 0x1a2b3c4d5e6f7082      0t0  TCP 127.0.0.1:8768 (LISTEN)
        tailscal  51900   mr   11u  IPv6 0x1a2b3c4d5e6f7083      0t0  TCP [::1]:41641 (LISTEN)
        tailscal  51900   mr   12u  IPv4 0x1a2b3c4d5e6f7084      0t0  TCP 127.0.0.1:1055 (LISTEN)
        """
        let found = Launchd.parseListening(captured)
        expect(found[52741] ?? 0, 8766, "hermes-map's port comes off its pid")
        expect(found[52802] ?? 0, 8767, "recon-journal's port comes off its pid")
        expect(found[52860] ?? 0, 8768, "recon-web's port comes off its pid")
        expect(found[51900] ?? 0, 1055, "a process on two ports shows the lower one")
        expect(found[1] ?? 0, 0, "a pid that listens on nothing has no port")
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

        // Finished while a turn was running: the notification is queued, and written as an
        // attachment rather than a user entry. A prompt typed over a working session, likewise.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m6","content":[{"type":"tool_use","id":"toolu_sh2","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh2","content":"Command running in background with ID: b2x2y2z. Output is being written to: /tmp/y"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell started in the background is a shell out")
        append(#"{"type":"attachment","timestamp":"\#(stamp(2))","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>b2x2y2z</task-id>\n<tool-use-id>toolu_sh2</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and a queued task-notification ends it")
        // A workflow reports back the same way a background shell does, and its journal says
        // how far it has got: the phase of the last agent started, that phase's agents done.
        // The last line is half-written, as it is while an agent is being started.
        let wf = root + "/session/subagents/workflows/wf_1"
        try? FileManager.default.createDirectory(atPath: wf, withIntermediateDirectories: true)
        try? #"export const meta = { name: 'break-history-audit', phases: [{ title: 'Map' }, { title: 'Verify', detail: 'x' }, { title: 'Synthesize' }] }"#
            .write(toFile: root + "/wf.js", atomically: true, encoding: .utf8)
        try? [#"{"type":"launched"}"#,
              #"{"type":"started","key":"k1","agentId":"a1","label":"map","phase":"Map"}"#,
              #"{"type":"result","key":"k1","value":"long"}"#,
              #"{"type":"started","key":"k2","agentId":"a2","label":"v:1","phase":"Verify"}"#,
              #"{"type":"started","key":"k3","agentId":"a3","label":"v:2","phase":"Verify"}"#,
              #"{"type":"result","key":"k2","value":"long"}"#,
              #"{"type":"started","key":"k4""#].joined(separator: "\n")
            .write(toFile: wf + "/journal.jsonl", atomically: true, encoding: .utf8)
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m7","content":[{"type":"tool_use","id":"toolu_wf","name":"Workflow","input":{"script":"x"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_wf","content":"Workflow launched in background. Task ID: w087be80a\nSummary: audit\nTranscript dir: \#(wf)\nScript file: \#(root)/wf.js\n"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a workflow launched is a task out")
        let pill = store.info(for: session)?.workflow?.pill() ?? "none"
        expect(pill == "50% · 0m · 0m left" ? 1 : 0, 1,
               "its journal reads as how far along, time so far, time to go (got \(pill))")
        append(#"{"type":"user","timestamp":"\#(stamp(2))","message":{"content":"<task-notification>\n<task-id>w087be80a</task-id>\n<tool-use-id>toolu_wf</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "and its task-notification ends it")
        let before = store.info(for: session)?.lastPromptAt
        append(#"{"type":"attachment","timestamp":"\#(stamp(1))","attachment":{"type":"queued_command","commandMode":"prompt","prompt":[{"type":"text","text":"and the icons"}]}}"#)
        let after = store.info(for: session)
        expect(after?.lastPromptAt != nil && after?.lastPromptAt != before ? 1 : 0, 1,
               "a prompt queued over a running turn counts as a prompt")
        expect(after?.preview.last?.text == "and the icons" ? 1 : 0, 1,
               "and shows on the tile")
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
