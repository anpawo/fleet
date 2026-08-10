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

    /// Parsed transcript for `path`. Unchanged files return the cached parse; changed ones are
    /// resumed from where the last read stopped.
    func info(for path: String) -> TranscriptInfo? {
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

        var state = resumable?.state ?? ParseState()
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

    /// Drops cache entries for transcripts no longer in use.
    func retain(paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }
}

// MARK: - Parsing

/// Everything the parse carries from one line to the next. Kept as a value so a refresh can
/// resume mid-file instead of re-reading what it already folded in.
private struct ParseState {
    var title: String?
    var lastPrompt: String?
    var permissionMode: String?
    var pending: [String: String] = [:]     // tool_use id -> tool name
    var preview: [PreviewLine] = []
    var turnOpen = false
    var lastCompleted: String?
    var cwd: String?

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

        // Sub-agent traffic is interleaved into the same file. Excluding it keeps the
        // pending-tool set describing the main thread only; a running sub-agent still
        // shows up as a pending `Task` call on the main thread.
        if obj["isSidechain"] as? Bool == true { return }

        guard let message = obj["message"] as? [String: Any] else { return }
        let blocks = Self.contentBlocks(message["content"])

        // Who spoke last, which is what says whether Claude still owes a reply. Only an
        // assistant message can close a turn; everything from the user side leaves it open,
        // and an open turn with nothing pending still looks exactly like a finished one.
        if type == "assistant" {
            turnOpen = false
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
                if let id = block["id"] as? String {
                    pending[id] = (block["name"] as? String) ?? "tool"
                }
                if let name = block["name"] as? String {
                    preview.append(PreviewLine(
                        kind: .tool,
                        text: Self.toolLabel(name: name, input: block["input"] as? [String: Any])))
                }
            case "tool_result":
                // A result is what makes a step *done*, so the completed step is named by the
                // tool_use it closes — not by the last tool_use we happened to see.
                if let id = block["tool_use_id"] as? String,
                   let name = pending.removeValue(forKey: id) {
                    lastCompleted = name
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
        TranscriptInfo(
            path: path,
            title: title,
            lastPrompt: lastPrompt,
            permissionMode: permissionMode,
            hasPendingTool: !pending.isEmpty,
            pendingToolNames: Array(pending.values),
            lastCompletedTool: lastCompleted,
            cwd: cwd,
            turnOpen: turnOpen,
            lastActivity: mtime,
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
