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
        reels(expect)
        crons(expect)
        judging(expect)
        repairs(expect)

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    // MARK: - Reels

    /// When a Reel that failed is tried again, and when it is given up on and named in ALERT.
    private static func reels(_ expect: (Bool, Bool, String) -> Void) {
        let now = Date()
        func reel(tries: Int?, triedAgo: TimeInterval?, status: String = "pending") -> Reel {
            var fields = ["status": ["stringValue": status]]
            if let tries { fields["fleetTries"] = ["integerValue": String(tries)] }
            if let triedAgo {
                fields["fleetTriedAt"] = ["timestampValue":
                    ISO8601DateFormatter().string(from: now.addingTimeInterval(-triedAgo))]
            }
            let json = try! JSONSerialization.data(withJSONObject: ["name": "factcheck/x", "fields": fields])
            return Reel(try! JSONDecoder().decode(Firestore.Document.self, from: json))
        }
        expect(reel(tries: nil, triedAgo: nil).needsCheck(at: now), true, "a Reel never tried is checked")
        expect(reel(tries: 1, triedAgo: 600).needsCheck(at: now), false,
               "a Reel that failed ten minutes ago waits")
        expect(reel(tries: 1, triedAgo: 3600).needsCheck(at: now), true,
               "a Reel that failed an hour ago is tried again")
        expect(reel(tries: nil, triedAgo: 3600).needsCheck(at: now), true,
               "a failure from before the count gets its retries")
        expect(reel(tries: Reel.maxTries, triedAgo: 86_400).needsCheck(at: now), false,
               "a Reel out of tries is left alone")
        expect(reel(tries: Reel.maxTries, triedAgo: 86_400).givenUp, true, "and is the one ALERT names")
        expect(reel(tries: 2, triedAgo: 600).givenUp, false, "a Reel with a try left is not in ALERT")
        expect(reel(tries: 1, triedAgo: 3600, status: "done").needsCheck(at: now), false,
               "a checked Reel is not checked again")
    }

    // MARK: - Crons

    /// When a routine's run is hung: past its next slot, within the floor and the ceiling —
    /// see `Launchd.allowance`. The age is `ps`'s etime, which has three shapes.
    private static func crons(_ expect: (TimeInterval?, TimeInterval?, String) -> Void) {
        expect(Launchd.parseElapsed("02-16:12:30"), 2 * 86400 + 16 * 3600 + 12 * 60 + 30, "etime with days")
        expect(Launchd.parseElapsed("16:12:30"), 16 * 3600 + 12 * 60 + 30, "etime with hours")
        expect(Launchd.parseElapsed("00:23"), 23, "etime under an hour")
        expect(Launchd.parseElapsed("1-2-03:04"), nil, "etime that is not one")
        let me = Int(getpid())
        expect(Launchd.elapsed([me])[me].map { $0 < 600 ? 1 : 0 }, 1, "ps answers for a live pid")

        let v3: [String: Any] = ["StartCalendarInterval": ["Minute": 5]]
        let epitech: [String: Any] = ["StartCalendarInterval": [8, 14, 20].map { ["Hour": $0, "Minute": 0] }]
        let weekdays: [String: Any] = ["StartCalendarInterval": (1...5).map { ["Weekday": $0, "Hour": 18, "Minute": 30] }]
        expect(Launchd.allowance(v3), 3600, "an hourly calendar job has an hour")
        expect(Launchd.allowance(epitech), 6 * 3600, "8h, 14h, 20h: the shortest gap, six hours")
        expect(Launchd.allowance(weekdays), 6 * 3600, "weekdays at 18:30: a day, down to the ceiling")
        expect(Launchd.allowance(["StartInterval": 60]), 300, "every minute: up to the floor")
        expect(Launchd.allowance(["StartInterval": 43200]), 6 * 3600, "every 12h: down to the ceiling")
        expect(Launchd.allowance(["WatchPaths": ["/tmp/x"]]), 6 * 3600, "a watched path: the ceiling")
        let online = ["/Users/mr/.local/bin/online", "/bin/bash", "routine.sh"]
        var v3online = v3
        v3online["ProgramArguments"] = online
        expect(Launchd.allowance(v3online), 3600 + 3 * 1295, "hourly under online: an hour and three waits of 21.5 min")
        expect(Launchd.hung(Launchd.parseElapsed("01:05:00"), v3online), nil,
               "a 20-min wait then a 45-min run is not hung")
        v3online["EnvironmentVariables"] = ["ONLINE_WAIT": "300"]
        expect(Launchd.allowance(v3online), 3600 + 3 * 395, "ONLINE_WAIT from the plist is the wait")
        var epitechOnline = epitech
        epitechOnline["ProgramArguments"] = online
        expect(Launchd.allowance(epitechOnline), 6 * 3600, "epitech under online: still the ceiling")
        expect(Launchd.hung(Launchd.parseElapsed("02:10:00"), v3), 7800, "recon-v3 running 2h10 is hung")
        expect(Launchd.hung(Launchd.parseElapsed("40:00"), v3), nil, "recon-v3 running 40 min is not")
        expect(Launchd.hung(Launchd.parseElapsed("04:00"), ["StartInterval": 60]), nil,
               "the mounts running 4 min are slow, not hung")
        expect(Launchd.hung(nil, v3), nil, "a routine between two runs is not hung")

        let now = Date()
        expect(Launchd.awake(3 * 3600, now: now, wake: now - 600), 600,
               "a run 3h old that slept through the night is 10 min awake")
        expect(Launchd.hung(Launchd.awake(3 * 3600, now: now, wake: now - 600), v3), nil,
               "and recon-v3 is not hung for it")
        expect(Launchd.awake(1800, now: now, wake: now - 7200), 1800, "a run started after the wake keeps its etime")
        expect(Launchd.awake(1800, now: now, wake: nil), 1800, "no wake since boot: etime as is")
        expect(Launchd.wakeTime().map { $0 < now ? 1 : 0 } ?? 1, 1, "kern.waketime reads as a past date or nothing")
    }

    /// What a plist and one `launchctl list` line make of a card and of ALERT.
    private static func judging(_ expect: (Bool, Bool, String) -> Void) {
        let hourly: [String: Any] = ["StartCalendarInterval": ["Minute": 5]]
        let resident: [String: Any] = ["KeepAlive": true]
        let late = Launchd.judge("s14.x", hourly, (nil, 75), age: nil)
        expect(late.deferred && !late.failing && late.ok, true, "exit 75: deferred, not failing, still ok")
        let failed = Launchd.judge("s14.x", hourly, (nil, 1), age: nil)
        expect(failed.failing && !failed.ok && !failed.deferred, true, "exit 1: failing, not ok")
        expect(Launchd.judge("s14.x", hourly, (nil, -15), age: nil).failing, true, "a kill is a failure")
        expect(Launchd.judge("s14.x", hourly, nil, age: nil).ok, false, "a routine launchd does not list is not ok")
        let stuck = Launchd.judge("s14.x", hourly, (42, 0), age: 7800)
        expect(stuck.hung == 7800 && !stuck.ok && stuck.busy, true, "running 2h10 on an hourly slot: hung, not ok")
        let up = Launchd.judge("s14.web", resident, (42, 78), age: 3 * 86400)
        expect(up.ok && up.hung == nil, true, "a resident up for days with an old 78 is ok, never hung")
        expect(Launchd.judge("s14.web", resident, (nil, 0), age: nil).ok, false, "a resident with no pid is not ok")
        expect(Launchd.judge("s14.web", resident, (42, 75), age: nil).deferred, false,
               "a resident whose last exit was 75 is not deferred")

        var retrying = failed
        retrying.repairing = true
        let lines = AlertsBlock.cronAlerts([stuck, failed, retrying, late, up,
                                            Launchd.judge("s14.web", resident, (nil, 1), age: nil)])
        expect(lines == ["s14.x hung 2h", "s14.x"], true,
               "ALERT: the hung one with its age, the failed one by name, nothing else (got \(lines))")
    }

    /// The retry state machine, on labels launchd does not have, with the kickstart counted
    /// rather than sent: what is checked is what Fleet remembers and what ALERT waits for.
    private static func repairs(_ expect: (Bool, Bool, String) -> Void) {
        let key = "cronRetries"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let store = LaunchdStore()
        store.repairs = true
        var kicked: [String] = []
        store.kick = { kicked.append($0); return true }
        func job(_ id: String, enabled: Bool = true, failing: Bool = false, busy: Bool = false,
                 deferred: Bool = false, hung: TimeInterval? = nil) -> Launchd.Job {
            Launchd.Job(id: id, name: id, schedule: "", enabled: enabled, failing: failing,
                        triggered: true, ok: !failing, note: "", busy: busy, deferred: deferred, hung: hung)
        }
        func remembers(_ id: String) -> Bool { UserDefaults.standard.dictionary(forKey: key)?[id] != nil }
        let now = Date()
        var out = store.repair([job("selftest.a", failing: true), job("selftest.b", deferred: true)], now: now)
        expect(out[0].repairing && remembers("selftest.a") && kicked == ["selftest.a"], true,
               "a failed routine is started again, and ALERT waits")
        expect(remembers("selftest.b"), false, "a deferred one is not started again")
        _ = store.repair([job("selftest.a", enabled: false)], now: now)
        expect(remembers("selftest.a"), true, "launchd listing nothing does not forget the retry")
        out = store.repair([job("selftest.a", failing: true)], now: now + 120)
        expect(out[0].repairing, false, "the retry failed too: not started a third time, ALERT names it")
        out = store.repair([job("selftest.a", failing: true, busy: true, hung: 7200)], now: now + 120)
        expect(out[0].repairing, false, "a retry that hangs is not waited for")
        _ = store.repair([job("selftest.e", busy: true, hung: 7200)], now: now)
        expect(remembers("selftest.e"), true, "a hung run spends the retry")
        _ = store.repair([job("selftest.e", busy: true, hung: 7210)], now: now + 10)
        expect(remembers("selftest.e"), true, "and keeps it spent while it hangs on an exit 0")
        out = store.repair([job("selftest.e", failing: true)], now: now + 20)
        expect(!out[0].repairing && !kicked.contains("selftest.e"), true,
               "killed by hand, it is named in ALERT, not started again")
        _ = store.repair([job("selftest.a")], now: now + 180)
        expect(remembers("selftest.a"), false, "a clean run forgets the retry")
        _ = store.repair([job("selftest.c", failing: true)], now: now)
        _ = store.repair([job("selftest.d")], now: now)
        expect(remembers("selftest.c"), false, "a routine gone from the folder is forgotten")
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
        // Done before its own tool_result is written: the notification is stamped first.
        append(#"{"type":"attachment","timestamp":"\#(stamp(4))","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>b4x4y4z</task-id>\n<tool-use-id>toolu_sh4</tool-use-id>\n<status>completed</status>\n</task-notification>"}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh4","content":"Command running in background with ID: b4x4y4z. Output is being written to: /tmp/w"}]}}"#)
        expect(store.info(for: session)?.backgroundShellsStartedAt.count ?? -1, 0,
               "a notification stamped before its shell's launch still ends it")
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
        expect(pill == "50% · 0m left" ? 1 : 0, 1,
               "its journal reads as how far along and time to go (got \(pill))")
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

        // A shell started well before the tail a cold read covers, and nothing ending it since:
        // a Fleet started now must still count it.
        append(#"{"type":"assistant","timestamp":"\#(stamp(4))","message":{"id":"m8","content":[{"type":"tool_use","id":"toolu_sh3","name":"Bash","input":{"command":"sleep 99"}}]}}"#)
        append(#"{"type":"user","timestamp":"\#(stamp(3))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_sh3","content":"Command running in background with ID: b3x3y3z. Output is being written to: /tmp/z"}]}}"#)
        let filler = #"{"type":"assistant","timestamp":"\#(stamp(2))","message":{"id":"m9","content":[{"type":"text","text":"\#(String(repeating: "x", count: 4000))"}]}}"#
        for _ in 0 ..< (Config.transcriptTailBytes / 4000 + 2) { append(filler) }
        expect(TranscriptStore().info(for: session)?.backgroundShellsStartedAt.count ?? -1, 1,
               "a shell started before the parsed tail is still a shell out after a restart")
    }

    // MARK: - Ghosts

    /// Two real processes, told apart only by the `CLAUDE_PID` they were started with: one names
    /// a pid nothing holds, the other names this process, which is alive and started first.
    private static func ghosts(_ expect: (Bool, Bool, String) -> Void) {
        var dead: pid_t = 99_000
        while kill(dead, 0) == 0 { dead += 1 }
        let installed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-check/Applications/sleep")
        try? FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installed)
        try? FileManager.default.copyItem(atPath: "/bin/sleep", toPath: installed.path)
        func spawn(owner: pid_t, from binary: String = "/bin/sleep") -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["30"]
            p.environment = ["CLAUDE_PID": String(owner)]
            try? p.run()
            return p
        }
        let orphan = spawn(owner: dead), child = spawn(owner: getpid())
        let app = spawn(owner: dead, from: installed.path)
        defer { orphan.terminate(); child.terminate(); app.terminate() }
        usleep(200_000)

        let found = Dictionary(uniqueKeysWithValues: Reaper.candidates().map { ($0.pid, $0.kind) })
        expect(found[orphan.processIdentifier] == .ghost, true, "ghosts: a tool process is a candidate")
        expect(app.isRunning && found[app.processIdentifier] == nil, true,
               "an installed app a session opened is not a ghost")
        expect(Reaper.ownerGone(orphan.processIdentifier), true, "its session gone, it is a ghost")
        expect(Reaper.ownerGone(child.processIdentifier), false, "its session alive, it is left alone")
    }
}
