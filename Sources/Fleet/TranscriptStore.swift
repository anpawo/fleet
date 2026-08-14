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
        info.subagents = liveSubagents(of: path, pendingTaskIDs: info.pendingTaskIDs)
        return info
    }

    /// Every sub-agent this session spawned that has not reported back.
    ///
    /// The pending `Task` calls are the authority on which are still running: a sub-agent's own
    /// files stay on disk long after it finishes, so the directory alone cannot tell a live one
    /// from last week's. Each `agent-*.meta.json` names the `tool_use` that spawned it, and a
    /// call still pending on the main thread is a sub-agent still working.
    private func liveSubagents(of sessionPath: String, pendingTaskIDs: [String]) -> [SubagentRun] {
        guard !pendingTaskIDs.isEmpty else {
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
        let wanted = Set(pendingTaskIDs)
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
        if resumable == nil, start > 0, !lines.isEmpty { lines.removeFirst() }

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
        } else if obj["isMeta"] as? Bool == true {
            // Not you talking. Claude Code files hook output, cross-session messages and its
            // own notes as user entries, and they land whenever they land — including after a
            // turn has finished. Treated as a prompt, one of those reopens a closed turn and
            // paints a session that is doing nothing as a session that is working.
        } else if blocks.contains(where: { $0["type"] as? String == "text" }) {
            // A user entry carrying real text is a prompt: the window between sending it and
            // Claude's first token.
            turnOpen = !Self.isInterruption(blocks)
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
                if let t = (block["text"] as? String)?.plainProse, !t.isEmpty {
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

    func info(path: String, mtime: Date) -> TranscriptInfo {
        // Newest call first: with several tools out, the one just issued is the step in flight.
        let inFlight = pending.values.sorted { $0.seq > $1.seq }
        return TranscriptInfo(
            path: path,
            title: title,
            lastPrompt: lastPrompt,
            permissionMode: permissionMode,
            hasPendingTool: !pending.isEmpty,
            pendingToolNames: inFlight.map(\.name),
            pendingToolLabels: inFlight.map(\.label),
            pendingTaskIDs: pending.filter { $0.value.name == "Task" }.map(\.key),
            lastCompletedTool: lastCompleted,
            cwd: cwd,
            turnOpen: turnOpen,
            lastActivity: mtime,
            lastMessageAt: lastMessageAt,
            preview: preview
        )
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
