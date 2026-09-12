import Foundation

/// `fleet --selftest`. The two pieces of this app whose rules only ever meet at runtime: which
/// number a tile wears, and whether a sub-agent is still working. Both are read from files
/// written by something else, so both are checked against files rather than mocks.
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

        numbering(expect)
        subagents(expect)

        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    // MARK: - Tile numbers

    private static func numbering(_ expect: ([String: Int], [String: Int], String) -> Void) {
        func numbers(_ registry: SessionRegistry,
                     _ names: [String], pins: [String: Int]) -> [String: Int] {
            var sessions = DemoFleet.sessions(names.count)
            for (i, name) in names.enumerated() {
                let dir = NSHomeDirectory() + "/self/" + name
                sessions[i].proc.cwd = dir
                sessions[i].transcript?.cwd = dir
                sessions[i].proc.startedAt = Date(timeIntervalSince1970: Double(1000 + i))
            }
            registry.assignNumbers(&sessions, pins: pins)
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.dirName, $0.number) })
        }

        // One registry per story, because what a pass does depends on what the last one left.
        let cold = SessionRegistry()
        expect(numbers(cold, ["a", "b", "c"], pins: [:]), ["a": 1, "b": 2, "c": 3],
               "no pins: oldest first, one to three")
        expect(numbers(cold, ["a", "b", "c"], pins: ["b": 1]), ["b": 1, "a": 2, "c": 3],
               "a pin outranks start order")
        expect(numbers(cold, ["a", "b", "c"], pins: [:]), ["b": 1, "a": 2, "c": 3],
               "dropping the pin does not reshuffle the tiles already up")

        let away = SessionRegistry()
        expect(numbers(away, ["a", "b"], pins: ["gone": 1]), ["a": 1, "b": 2],
               "a pinned project that is away leaves its number open")
        expect(numbers(away, ["a", "b", "gone"], pins: ["gone": 1]),
               ["gone": 1, "b": 2, "a": 3],
               "and takes it back when it starts — only the squatter moves")

        expect(Slots.parse("""
        # 9 commented
        2 my-hub
        3\tfleet     # trailing comment
        12 too-high
        rubbish
        """), ["my-hub": 2, "fleet": 3], "slots: comments, tabs and junk lines")
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
    }
}
