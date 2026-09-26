import Foundation

/// Reads Claude Code's JSONL transcripts and caches the parsed result.
///
/// Two things keep this cheap enough to run continuously. A file is only touched at all when
/// its size or mtime moved — otherwise a refresh is one `stat` per session. And when it *has*
/// moved, only the bytes appended since the last read are parsed: the parse is a fold over
/// lines, so its state is carried in the cache and resumed rather than rebuilt. A busy session
/// appends a few KB between refreshes, which is the work we do, instead of re-reading 256 KB.
final class TranscriptStore {

    private struct CacheEntry {
        var size: Int
        var mtime: Date
        /// Byte offset just past the last complete line folded into `state`.
        var offset: UInt64
        var state: ParseState
        var info: TranscriptInfo
    }

    private var cache: [String: CacheEntry] = [:]
    /// Sub-agent files read on behalf of a session, so `retain` keeps them cached too. Without
    /// this they are evicted on every refresh and re-read from cold, which is the expensive
    /// path — the whole point of the cache is that a live file is parsed incrementally.
    private var subagentPaths: [String: Set<String>] = [:]

    /// Root of Claude Code's per-project transcript storage.
    static let projectsRoot = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/projects")

    /// Claude Code maps a working directory to a folder name by replacing every character
    /// outside [A-Za-z0-9] with "-". e.g. /Users/mr/.claude -> -Users-mr--claude
    static func projectDirectory(for cwd: String) -> String {
        let mapped = String(cwd.map { ch in
            ch.isLetter || ch.isNumber ? ch : "-"
        })
        return (projectsRoot as NSString).appendingPathComponent(mapped)
    }

    struct TranscriptFile {
        var path: String
        var sessionID: String
        var birth: Date
        var mtime: Date
    }

    /// Every transcript belonging to a working directory, newest activity first.
    static func transcripts(for cwd: String) -> [TranscriptFile] {
        let dir = projectDirectory(for: cwd)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        var files: [TranscriptFile] = []
        for name in names where name.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            let birth = (attrs[.creationDate] as? Date) ?? mtime
            files.append(TranscriptFile(
                path: path,
                sessionID: String(name.dropLast(6)),
                birth: birth,
                mtime: mtime
            ))
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    /// Every transcript across every project, appended to within `window`, newest first.
    ///
    /// Used only to rescue a session whose transcript is not where its working directory says it
    /// should be — see the last binding pass. The recency window is what keeps this affordable:
    /// a live session appends constantly, so anything untouched for minutes cannot be the file
    /// we are hunting for, and never gets opened.
    static func recentTranscripts(within window: TimeInterval) -> [TranscriptFile] {
        let cutoff = Date().addingTimeInterval(-window)
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else {
            return []
        }
        var files: [TranscriptFile] = []
        for dir in dirs {
            let full = (projectsRoot as NSString).appendingPathComponent(dir)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else {
                continue
            }
            for name in names where name.hasSuffix(".jsonl") {
                let path = (full as NSString).appendingPathComponent(name)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else {
                    continue
                }
                files.append(TranscriptFile(
                    path: path,
                    sessionID: String(name.dropLast(6)),
                    birth: (attrs[.creationDate] as? Date) ?? mtime,
                    mtime: mtime
                ))
            }
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    /// Parsed transcript for `path`, plus whatever sub-agents it is currently waiting on.
    func info(for path: String) -> TranscriptInfo? {
        guard var info = parse(path: path, acceptSidechain: false) else { return nil }
        info.subagents = liveSubagents(of: path,
                                       spawns: info.pendingTaskIDs + info.unfinishedAgentIDs)
        info.workflow = info.workflows.last.flatMap(progress(of:))
        return info
    }

    /// What a workflow's journal says so far, read from where the last read stopped: the
    /// journal carries every agent's full result and runs to megabytes.
    private struct Tally {
        var offset: UInt64 = 0
        var phase: String?
        var phaseOf: [String: String] = [:]
        var started: [String: Int] = [:]
        var done: [String: Int] = [:]
    }
    private var tallies: [String: Tally] = [:]
    private var scriptMeta: [String: (name: String, phases: [String])] = [:]

    private func progress(of run: WorkflowLaunch) -> WorkflowProgress? {
        let path = (run.dir as NSString).appendingPathComponent("journal.jsonl")
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var tally = tallies[path] ?? Tally()
        let size = (try? handle.seekToEnd()) ?? 0
        if size < tally.offset { tally = Tally() }
        try? handle.seek(toOffset: tally.offset)
        let data = handle.readDataToEndOfFile()
        // Only whole lines: the one being written is read again next time, complete.
        if let end = data.lastIndex(of: UInt8(ascii: "\n")) {
            tally.offset += UInt64(end - data.startIndex + 1)
            for line in data[..<end].split(separator: UInt8(ascii: "\n")) {
                // Results are the big lines and only their key matters, so nothing is decoded
                // past the head of a line.
                let head = String(decoding: line.prefix(400), as: UTF8.self)
                guard let key = Self.jsonString("key", in: head) else { continue }
                if head.hasPrefix(#"{"type":"started""#) {
                    let phase = Self.jsonString("phase", in: head) ?? ""
                    tally.phaseOf[key] = phase
                    tally.phase = phase
                    tally.started[phase, default: 0] += 1
                } else if head.hasPrefix(#"{"type":"result""#), let phase = tally.phaseOf[key] {
                    tally.done[phase, default: 0] += 1
                }
            }
        }
        tallies[path] = tally

        let meta = scriptMeta[run.script] ?? {
            let text = (try? String(contentsOfFile: run.script, encoding: .utf8)) ?? ""
            let name = Self.firstMatch(#"name:\s*['"]([^'"]+)"#, in: text) ?? "workflow"
            let list = text.range(of: "phases:").map { String(text[$0.upperBound...].prefix { $0 != "]" }) } ?? ""
            let phases = Self.allMatches(#"title:\s*['"]([^'"]+)"#, in: list)
            scriptMeta[run.script] = (name, phases)
            return (name, phases)
        }()
        let phase = tally.phase.flatMap { $0.isEmpty ? nil : $0 }
        let key = tally.phase ?? ""
        return WorkflowProgress(
            name: meta.name,
            phase: phase,
            phaseIndex: phase.flatMap { meta.phases.firstIndex(of: $0) }.map { $0 + 1 },
            phaseCount: meta.phases.count,
            done: tally.done[key] ?? 0,
            started: tally.started[key] ?? 0,
            since: run.since
        )
    }

    /// `"field":"value"` in a line of JSON, without decoding the line.
    private static func jsonString(_ field: String, in text: String) -> String? {
        firstMatch("\"\(field)\":\"([^\"]*)\"", in: text)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Every sub-agent this session spawned that has not reported back.
    ///
    /// A sub-agent's own files stay on disk long after it finishes, so the directory alone
    /// cannot tell a live one from last week's — the main transcript is the authority. Each
    /// `agent-*.meta.json` names the `tool_use` that spawned it, and that call is either still
    /// pending, which means the main thread is blocked on it, or answered at once and closed
    /// later by a `<task-notification>`, which means the agent has been working in the
    /// background all along. Both are handed in here; neither costs a directory listing when
    /// there is nothing out.
    private func liveSubagents(of sessionPath: String, spawns: [String]) -> [SubagentRun] {
        guard !spawns.isEmpty else {
            // Nothing delegated: no directory listing, no reads, nothing to keep cached.
            subagentPaths[sessionPath] = nil
            return []
        }
        let dir = ((sessionPath as NSString).deletingPathExtension as NSString)
            .appendingPathComponent("subagents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }

        let suffix = ".meta.json"
        let wanted = Set(spawns)
        var runs: [SubagentRun] = []
        var read: Set<String> = []

        for name in names.sorted() where name.hasSuffix(suffix) {
            guard runs.count < Config.maxLiveSubagents else { break }
            let metaPath = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: metaPath),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolUseID = meta["toolUseId"] as? String,
                  wanted.contains(toolUseID) else { continue }

            let id = String(name.dropLast(suffix.count))
            let agentPath = (dir as NSString).appendingPathComponent(id + ".jsonl")
            // A sub-agent's transcript is entirely sidechain traffic — that flag is what marks
            // it as not belonging to the main thread — so it is read with the filter off.
            let info = parse(path: agentPath, acceptSidechain: true)
            read.insert(agentPath)

            runs.append(SubagentRun(
                id: id,
                kind: (meta["agentType"] as? String) ?? "agent",
                task: (meta["description"] as? String) ?? "",
                // What it is doing beats what it last said, and a sub-agent that is thinking
                // rather than running something has only the latter. Flattened and clipped:
                // what it last said is prose, and this lands on a single tile line.
                step: (info?.pendingToolLabels.first ?? info?.preview.last?.text)
                    .map { String($0.collapsedWhitespace.prefix(90)) },
                lastActivity: info?.lastActivity ?? .distantPast
            ))
        }

        subagentPaths[sessionPath] = read
        // Stable order, so the tile keeps naming the same one instead of cycling through them
        // as the directory listing comes back in whatever order it likes.
        return runs.sorted { $0.id < $1.id }
    }

    /// Parsed JSONL at `path`. Unchanged files return the cached parse; changed ones are
    /// resumed from where the last read stopped.
    private func parse(path: String, acceptSidechain: Bool) -> TranscriptInfo? {
        // Never downgrade to nil once a file has been read. A nil transcript is not a neutral
        // "unknown" downstream — the tile falls back to the process cwd for its name, loses its
        // step line, and reports READY whatever the session is doing. A transient read failure
        // must not look like that.
        let previous = cache[path]?.info

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return previous
        }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast

        if let hit = cache[path], hit.size == size, hit.mtime == mtime {
            return hit.info
        }

        // Resume only when the file grew on the end we already read. A shrink means it was
        // rewritten or rotated, and the offsets we hold no longer mean anything.
        let resumable = cache[path].flatMap { hit -> CacheEntry? in
            UInt64(size) >= hit.offset ? hit : nil
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return previous }
        defer { try? handle.close() }

        var state = resumable?.state ?? ParseState(acceptSidechain: acceptSidechain)
        let start = resumable?.offset ?? Self.tailStart(size: UInt64(size))
        try? handle.seek(toOffset: start)
        // `readToEnd` reports EOF as nil, not as empty data, and seeking to a resume offset that
        // is already the end of the file is the normal case: mtime moves the moment a line is
        // being written, so a refresh regularly lands with nothing yet to read.
        let data = (try? handle.readToEnd()) ?? Data()

        // Stop at the last newline: a transcript is appended to while we read it, so the final
        // line can be half-written. Leaving it unconsumed means it is picked up whole next time.
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // Nothing complete to fold in. Record what we saw so the next refresh doesn't repeat
            // this read, and keep the parse we already have.
            if var hit = resumable {
                hit.size = size
                hit.mtime = mtime
                cache[path] = hit
            }
            return previous
        }
        let complete = data[..<lastBreak]
        var lines = complete.split(separator: UInt8(ascii: "\n"))
        // A cold read starting mid-file opens on a fragment; a resumed one starts on a boundary.
        if resumable == nil, start > 0, !lines.isEmpty {
            lines.removeFirst()
            // A shell sent to the background hours ago is still out when nothing since has
            // ended it, and that "since" can be megabytes: a Fleet restarted with the start
            // past the tail read the session as finished. Only the lines that start or end
            // one are worth the head of the file, and they say so in fixed words.
            try? handle.seek(toOffset: 0)
            let head = (try? handle.read(upToCount: Int(start))) ?? Data()
            for raw in head.split(separator: UInt8(ascii: "\n"))
            where Self.delegationMarks.contains(where: { raw.range(of: $0) != nil }) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] {
                    state.ingest(obj)
                }
            }
        }

        for raw in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any]
            else { continue }
            state.ingest(obj)
        }

        let consumed = start + UInt64(complete.count) + 1   // +1 for the newline itself
        let info = state.info(path: path, mtime: mtime)
        cache[path] = CacheEntry(size: size, mtime: mtime, offset: consumed,
                                 state: state, info: info)
        return info
    }

    private static let delegationMarks = ["background with ID", "moved to the background",
                                          "Workflow launched in background", "<task-notification>",
                                          "Successfully stopped task"].map { Data($0.utf8) }

    /// Sessions are long and only recent state matters, so a cold read starts near the end.
    private static func tailStart(size: UInt64) -> UInt64 {
        size > UInt64(Config.transcriptTailBytes)
            ? size - UInt64(Config.transcriptTailBytes) : 0
    }

    /// Drops cache entries for transcripts no longer in use, keeping the sub-agent files read
    /// on behalf of the sessions that survive.
    func retain(paths: Set<String>) {
        subagentPaths = subagentPaths.filter { paths.contains($0.key) }
        let keep = paths.union(subagentPaths.values.joined())
        cache = cache.filter { keep.contains($0.key) }
    }
}

// MARK: - Parsing

/// Everything the parse carries from one line to the next. Kept as a value so a refresh can
/// resume mid-file instead of re-reading what it already folded in.
private struct ParseState {
    /// One tool call still waiting on its result.
    struct PendingTool {
        var name: String        // "Bash"
        var label: String       // "Bash npm test"
        /// Order it was issued in, so "the step in flight" can mean the most recent one rather
        /// than whichever the dictionary hands back first.
        var seq: Int
        /// The assistant message this call was part of. Several calls issued together share
        /// one; a *later* message means every earlier call has been answered — see `ingest`.
        var messageID: String?
    }

    /// Sub-agent transcripts are made *entirely* of sidechain entries, so reading one means
    /// keeping what a main transcript drops. See the filter in `ingest`.
    var acceptSidechain = false

    var title: String?
    var lastPrompt: String?
    /// The last brief a peer session sent this one. For a session driven by message rather
    /// than by prompt, Claude Code writes no `ai-title` and no `last-prompt`, so this is the
    /// only thing in the file that says what the session is *for* — and unlike the last thing
    /// Claude said, it does not change every turn.
    var briefing: String?
    /// The pid in that brief's `from="uds:/tmp/cc-socks/<pid>.sock"` — which session sent it.
    var briefedBy: pid_t?
    var permissionMode: String?
    var pending: [String: PendingTool] = [:]    // tool_use id -> the call
    var issued = 0
    var preview: [PreviewLine] = []
    var turnOpen = false
    var lastCompleted: String?
    var cwd: String?
    /// When the last conversation entry was written, from its own stamp. Not the file's mtime:
    /// Claude Code appends `ai-title`, `last-prompt` and `mode` lines seconds *after* a turn
    /// ends, so the mtime of a session that has finished keeps moving while nothing is being
    /// said. Every "has it gone quiet" question here means this, not the file.
    var lastMessageAt: Date?
    /// When you last sent this session a prompt. A task notification waking it up is not you.
    var lastPromptAt: Date?
    /// Agent spawns and endings, by the `tool_use` id that started them. A spawn whose id has
    /// no later ending is an agent still working — see `TranscriptInfo.unfinishedAgentIDs`.
    /// Both outlive the entries they came from: an async agent's spawn and its notification can
    /// be a quarter of an hour and several turns apart.
    var agentSpawnedAt: [String: Date] = [:]
    var agentEndedAt: [String: Date] = [:]
    /// Shell commands running in the background, by the `tool_use` that started them. Their
    /// call is answered at once too, and ended the same way: a `<task-notification>` naming it,
    /// recorded in `agentEndedAt` like an agent's.
    var shellSpawnedAt: [String: Date] = [:]
    /// Task id → the `tool_use` that started that shell. `TaskStop` names the task, not the
    /// call, and a stopped shell sends no notification — this is the only way to close it.
    var shellCallByTask: [String: String] = [:]
    /// A workflow's own files, by the `tool_use` that launched it — the rest of its life is
    /// a shell's, in `shellSpawnedAt`.
    var workflowFiles: [String: (dir: String, script: String)] = [:]

    mutating func ingest(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }

        // Every conversation entry stamps the session's *current* directory, which is not the
        // process cwd: `cd` inside a session moves this and leaves the process where it
        // launched. This is the directory the session is actually working in.
        if let d = obj["cwd"] as? String, !d.isEmpty { cwd = d }

        switch type {
        case "ai-title":
            if let t = obj["aiTitle"] as? String { title = t }
            return
        case "last-prompt":
            if let p = obj["lastPrompt"] as? String { lastPrompt = p }
            return
        case "permission-mode":
            if let m = obj["permissionMode"] as? String { permissionMode = m }
            return
        case "attachment":
            ingestQueued(obj)
            return
        case "assistant", "user":
            break
        default:
            return
        }

        // Sidechain entries are a sub-agent's own traffic. In a main transcript they are
        // dropped, so the pending-tool set describes the main thread only — a running
        // sub-agent shows up there as a pending `Task` call, which is what we want. When the
        // file being read *is* the sub-agent's, they are all there is.
        if !acceptSidechain, obj["isSidechain"] as? Bool == true { return }

        guard let message = obj["message"] as? [String: Any] else { return }
        let blocks = Self.contentBlocks(message["content"])
        let messageID = message["id"] as? String
        if let stamp = obj["timestamp"] as? String, let at = Self.date(stamp) { lastMessageAt = at }

        // A turn cancelled with Esc names the message it cut short, and the tool calls in that
        // message are never answered — nothing is coming back for them. Left in `pending` they
        // are a step permanently in flight, which reads as a session that is working and, in
        // bypass mode, never even ages into "waiting for you". So the cancelled call goes.
        if let cut = obj["interruptedMessageId"] as? String {
            pending = pending.filter { $0.value.messageID != cut }
        }

        // The same thing, for the cancellations that do not name a message: the marker entry
        // is written in place of the reply, so anything still out belonged to the turn it cut.
        if type == "user", Self.isInterruption(blocks) { pending.removeAll() }

        // A new assistant message means every call from an *earlier* one has been answered:
        // the API will not take a further turn while a `tool_use` is outstanding, so a call
        // still pending here was resolved by a result the parsed tail never covered — the tail
        // window cut it off, or the line was dropped. Calls issued together share a message id
        // and are left alone; only the older ones are cleared.
        if type == "assistant", let messageID {
            pending = pending.filter { $0.value.messageID == messageID }
        }

        // Who spoke last, which is what says whether Claude still owes a reply. Only an
        // assistant message can close a turn; everything from the user side leaves it open,
        // and an open turn with nothing pending still looks exactly like a finished one.
        if type == "assistant" {
            turnOpen = false
        } else if obj["isMeta"] as? Bool == true || Self.isLocalCommand(blocks) {
            // Not you talking. Claude Code files hook output, cross-session messages and its
            // own notes as user entries, and they land whenever they land — including after a
            // turn has finished. Treated as a prompt, one of those reopens a closed turn and
            // paints a session that is doing nothing as a session that is working.
            //
            // A slash command that runs locally (`/model`, `/config`…) is the same thing
            // without the flag: three user entries, and Claude never answers them.
        } else if blocks.contains(where: { $0["type"] as? String == "text" }) {
            // A user entry carrying real text is a prompt: the window between sending it and
            // Claude's first token.
            turnOpen = !Self.isInterruption(blocks)
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            if !text.contains("<task-notification>") { lastPromptAt = lastMessageAt }
        } else if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            // A tool result is also a "user" entry, and it ends nothing: the protocol requires
            // Claude to answer it, so the turn is still running. Missing this was why a session
            // showed green for the whole stretch between a tool finishing and the next step
            // appearing — on a slow command, most of its working life.
            turnOpen = true
        }

        for block in blocks {
            guard let kind = block["type"] as? String else { continue }
            switch kind {
            case "text":
                // "A task-notification fires each time this agent stops" — so the last one
                // wins, and an agent resumed after one is missed until it stops again. That is
                // the whole cost of never listing a directory while nothing is out.
                if let raw = block["text"] as? String, raw.contains("<task-notification>"),
                   let call = Self.tagged("tool-use-id", in: raw) {
                    agentEndedAt[call] = lastMessageAt ?? Date()
                }
                if type == "user", let raw = block["text"] as? String,
                   let brief = Self.briefed(in: raw) {
                    briefing = brief.text
                    briefedBy = brief.from
                }
                // Not the entries Claude Code writes on your behalf — a pasted image's
                // "[Image: source: <path>]", hook output, a skill's instructions. None of it is
                // anything you said, and a cache path is all a tile row had room for.
                if obj["isMeta"] as? Bool != true,
                   let t = (block["text"] as? String)?.plainProse.collapsedWhitespace
                       .replacingOccurrences(of: #"\[Image #(\d+)\]"#, with: "image$1",
                                             options: .regularExpression), !t.isEmpty {
                    // Capped: this state outlives a single read now, and a reply runs for pages.
                    preview.append(PreviewLine(kind: type == "user" ? .user : .assistant,
                                               text: String(t.prefix(200))))
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let label = Self.toolLabel(name: name, input: block["input"] as? [String: Any])
                if let id = block["id"] as? String {
                    issued += 1
                    pending[id] = PendingTool(name: name, label: label, seq: issued,
                                              messageID: messageID)
                    if Self.agentTools.contains(name) {
                        agentSpawnedAt[id] = lastMessageAt ?? Date()
                    }
                }
                if block["name"] is String {
                    preview.append(PreviewLine(kind: .tool, text: label))
                }
            case "tool_result":
                // A result is what makes a step *done*, so the completed step is named by the
                // tool_use it closes — not by the last tool_use we happened to see.
                if let id = block["tool_use_id"] as? String,
                   let done = pending.removeValue(forKey: id) {
                    lastCompleted = done.name
                }
                // `run_in_background`, a command that outlived its timeout and was moved
                // there, or a workflow: the result says so in its first words, either way. Prefix only — a
                // session reading this very file would otherwise match its own source.
                if let id = block["tool_use_id"] as? String {
                    let texts = Self.resultText(block["content"])
                    if texts.contains(where: {
                        $0.hasPrefix("Command running in background with ID")
                            || $0.hasPrefix("Command did not complete within")
                            || $0.hasPrefix("Workflow launched in background")
                    }) {
                        shellSpawnedAt[id] = lastMessageAt ?? Date()
                        if let dir = Self.field("Transcript dir: ", in: texts),
                           let script = Self.field("Script file: ", in: texts) {
                            workflowFiles[id] = (dir, script)
                        }
                        if let task = texts.lazy.compactMap(Self.taskID(in:)).first {
                            shellCallByTask[task] = id
                        }
                    }
                    // Stopped by hand: no notification will ever come for it.
                    for t in texts {
                        if let r = t.range(of: "Successfully stopped task: "),
                           let call = shellCallByTask[Self.token(t, from: r.upperBound)] {
                            agentEndedAt[call] = lastMessageAt ?? Date()
                        }
                    }
                }
            default:
                continue
            }
        }

        // Bounded here rather than at the end: the state outlives a single read now, so an
        // unbounded preview would grow for as long as the session lives.
        if preview.count > Config.previewLineCount {
            preview.removeFirst(preview.count - Config.previewLineCount)
        }
    }

    /// Anything that arrives while a turn is running — a prompt you typed over a working
    /// session, a task's completion — is queued and written as an `attachment` of type
    /// `queued_command`, never as a `user` entry. Read only from there, a prompt sent mid-turn
    /// never counts as a prompt and a shell that finished mid-turn never finishes.
    private mutating func ingestQueued(_ obj: [String: Any]) {
        guard let queued = obj["attachment"] as? [String: Any],
              queued["type"] as? String == "queued_command" else { return }
        let at = (obj["timestamp"] as? String).flatMap(Self.date) ?? Date()
        let text = queued["prompt"] as? String
            ?? Self.contentBlocks(queued["prompt"]).compactMap { $0["text"] as? String }.joined()
        if text.contains("<task-notification>") {
            if let call = Self.tagged("tool-use-id", in: text) { agentEndedAt[call] = at }
        } else if queued["commandMode"] as? String == "prompt" {
            lastPromptAt = at
            let t = text.plainProse.collapsedWhitespace
                .replacingOccurrences(of: #"\[Image #(\d+)\]"#, with: "image$1", options: .regularExpression)
            if !t.isEmpty {
                preview.append(PreviewLine(kind: .user, text: String(t.prefix(200))))
                if preview.count > Config.previewLineCount { preview.removeFirst() }
            }
        }
    }

    func info(path: String, mtime: Date) -> TranscriptInfo {
        // Newest call first: with several tools out, the one just issued is the step in flight.
        let inFlight = pending.values.sorted { $0.seq > $1.seq }
        return TranscriptInfo(
            path: path,
            title: title,
            lastPrompt: lastPrompt,
            lastPromptAt: lastPromptAt,
            briefing: briefing,
            briefedBy: briefedBy,
            permissionMode: permissionMode,
            hasPendingTool: !pending.isEmpty,
            pendingToolNames: inFlight.map(\.name),
            pendingToolLabels: inFlight.map(\.label),
            pendingTaskIDs: pending.filter { Self.agentTools.contains($0.value.name) }.map(\.key),
            unfinishedAgentIDs: agentSpawnedAt
                .filter { (agentEndedAt[$0.key] ?? .distantPast) < $0.value }
                .map(\.key),
            backgroundShellsStartedAt: shellSpawnedAt
                .filter { (agentEndedAt[$0.key] ?? .distantPast) < $0.value }
                .map(\.value),
            lastCompletedTool: lastCompleted,
            cwd: cwd,
            turnOpen: turnOpen,
            lastActivity: mtime,
            lastMessageAt: lastMessageAt,
            preview: preview,
            workflows: workflowFiles.compactMap { id, files in
                guard let since = shellSpawnedAt[id],
                      (agentEndedAt[id] ?? .distantPast) < since else { return nil }
                return WorkflowLaunch(dir: files.dir, script: files.script, since: since)
            }.sorted { $0.since < $1.since }
        )
    }

    /// The rest of the line after `label`, in whichever text has it.
    static func field(_ label: String, in texts: [String]) -> String? {
        for t in texts {
            guard let r = t.range(of: label) else { continue }
            let value = t[r.upperBound...].prefix { $0 != "\n" }
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// A tool result's text, whether Claude Code wrote it as a string or as text blocks.
    static func resultText(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
    }

    /// What spawns a sub-agent. "Task" is what it was called before 2.1 and still answers to.
    static let agentTools: Set<String> = ["Agent", "Task"]

    /// The contents of `<tag>…</tag>`, or nil. `task-notification` is the one XML block Claude
    /// Code writes into a transcript as prose, and one tag is not worth a parser.
    static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound ..< text.endIndex)
        else { return nil }
        return String(text[open.upperBound ..< close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body of a `<cross-session-message …>`, whose opening tag carries attributes and so
    /// never matches `tagged`.
    static func briefed(in text: String) -> (text: String, from: pid_t?)? {
        guard let open = text.range(of: "<cross-session-message"),
              let gt = text.range(of: ">", range: open.upperBound ..< text.endIndex),
              let close = text.range(of: "</cross-session-message>",
                                     range: gt.upperBound ..< text.endIndex)
        else { return nil }
        // A brief often opens on a bare path or an id on its own line. Collapsing first made
        // that the card's name, which says where and never what — so the first line with a
        // space in it wins, and the naked ones above it are skipped.
        let prose = String(text[gt.upperBound ..< close.lowerBound]).plainProse
        let body = (prose.split(whereSeparator: \.isNewline).first { $0.contains(" ") }
            .map(String.init) ?? prose).collapsedWhitespace
        guard !body.isEmpty else { return nil }
        // from="uds:/tmp/cc-socks/46206.sock" — the socket is named after the sender's pid, and
        // that is the only thing in the message that ties it to a card on the panel.
        let header = String(text[open.upperBound ..< gt.lowerBound])
        var from: pid_t?
        if let sock = header.range(of: "cc-socks/") {
            let digits = header[sock.upperBound...].prefix { $0.isNumber }
            from = pid_t(digits)
        }
        return (body, from)
    }

    /// The task id in "…background with ID: b1x2y3z" or "…background (ID: b1x2y3z)".
    static func taskID(in text: String) -> String? {
        guard let r = text.range(of: "ID: ") else { return nil }
        let id = token(text, from: r.upperBound)
        return id.isEmpty ? nil : id
    }

    /// The word starting at `from`, up to the first character no task id contains.
    static func token(_ text: String, from: String.Index) -> String {
        String(text[from...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "@" })
    }

    /// "Bash" says a command ran; "Bash ./install.sh" says which. The argument that identifies
    /// the work differs per tool, and anything unrecognised just keeps its name.
    static func toolLabel(name: String, input: [String: Any]?) -> String {
        guard let input else { return name }
        let detail: String?
        switch name {
        case "Bash", "BashOutput":
            detail = input["command"] as? String
        case "Read", "Edit", "Write", "NotebookEdit":
            detail = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            detail = input["pattern"] as? String
        case "Task", "Skill":
            detail = (input["description"] as? String) ?? (input["skill"] as? String)
        case "WebFetch", "WebSearch":
            detail = (input["url"] as? String) ?? (input["query"] as? String)
        default:
            detail = nil
        }
        guard let d = detail?.collapsedWhitespace, !d.isEmpty else { return name }
        return "\(name) \(d.prefix(80))"
    }

    /// Cancelling a turn with Esc appends a user entry too. Without this the session would
    /// sit at "working" forever, since no assistant reply is ever coming.
    private static func isLocalCommand(_ blocks: [[String: Any]]) -> Bool {
        blocks.contains { block in
            guard let text = block["text"] as? String else { return false }
            return text.hasPrefix("<local-command-") || text.hasPrefix("<command-name>")
        }
    }

    private static func isInterruption(_ blocks: [[String: Any]]) -> Bool {
        blocks.contains { block in
            guard let text = block["text"] as? String else { return false }
            return text.hasPrefix("[Request interrupted")
        }
    }

    /// Entry stamps are ISO 8601 with fractional seconds, and the formatter is held rather
    /// than made per line: a busy refresh parses hundreds of them.
    private static let stamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainStamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ stamp: String) -> Date? {
        stamps.date(from: stamp) ?? plainStamps.date(from: stamp)
    }

    /// Message content is either a bare string or an array of typed blocks.
    private static func contentBlocks(_ content: Any?) -> [[String: Any]] {
        if let s = content as? String {
            return [["type": "text", "text": s]]
        }
        if let arr = content as? [[String: Any]] { return arr }
        return []
    }
}

private extension String {
    /// Strips the markdown Claude writes in, which is noise at tile size: emphasis markers,
    /// code ticks, and leading list/heading punctuation. Not a parser — just the handful of
    /// characters that show up as literal clutter in a one-line summary.
    var plainProse: String {
        var out = replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "__", with: "")
            // A reply opening on a code fence leaves its newline in front once the backticks go,
            // and a one-line row shows only that empty first line.
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = out.first, "#->*•".contains(first) {
            out.removeFirst()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Flattens a message to a single line so it fits a tile row.
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
