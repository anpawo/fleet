import Foundation

/// Reads Claude Code's JSONL transcripts and caches the parsed result.
///
/// Transcripts grow to megabytes, so only the tail is read, and a file is re-parsed only when
/// its size or mtime actually changed. In the common case a refresh is one `stat` per session.
final class TranscriptStore {

    private struct CacheEntry {
        var size: Int
        var mtime: Date
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

    /// Parsed transcript for `path`, reusing the cached parse when the file is unchanged.
    func info(for path: String) -> TranscriptInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast

        if let hit = cache[path], hit.size == size, hit.mtime == mtime {
            return hit.info
        }
        guard let parsed = Self.parse(path: path, mtime: mtime) else { return nil }
        cache[path] = CacheEntry(size: size, mtime: mtime, info: parsed)
        return parsed
    }

    /// Drops cache entries for transcripts no longer in use.
    func retain(paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    // MARK: - Parsing

    private static func parse(path: String, mtime: Date) -> TranscriptInfo? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let total = (try? handle.seekToEnd()) ?? 0
        let start = total > UInt64(Config.transcriptTailBytes)
            ? total - UInt64(Config.transcriptTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        // When we started mid-file the first line is a fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var title: String?
        var lastPrompt: String?
        var permissionMode: String?
        var pending: [String: String] = [:]     // tool_use id -> tool name
        var preview: [PreviewLine] = []

        for raw in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any]
            else { continue }
            guard let type = obj["type"] as? String else { continue }

            switch type {
            case "ai-title":
                if let t = obj["aiTitle"] as? String { title = t }
                continue
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String { lastPrompt = p }
                continue
            case "permission-mode":
                if let m = obj["permissionMode"] as? String { permissionMode = m }
                continue
            case "assistant", "user":
                break
            default:
                continue
            }

            // Sub-agent traffic is interleaved into the same file. Excluding it keeps the
            // pending-tool set describing the main thread only; a running sub-agent still
            // shows up as a pending `Task` call on the main thread.
            if obj["isSidechain"] as? Bool == true { continue }

            guard let message = obj["message"] as? [String: Any] else { continue }
            let blocks = contentBlocks(message["content"])

            for block in blocks {
                guard let kind = block["type"] as? String else { continue }
                switch kind {
                case "text":
                    if let t = (block["text"] as? String)?.collapsedWhitespace, !t.isEmpty {
                        preview.append(PreviewLine(
                            kind: type == "user" ? .user : .assistant, text: t))
                    }
                case "tool_use":
                    if let id = block["id"] as? String {
                        pending[id] = (block["name"] as? String) ?? "tool"
                    }
                    if let name = block["name"] as? String {
                        preview.append(PreviewLine(kind: .tool, text: name))
                    }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { pending.removeValue(forKey: id) }
                default:
                    continue
                }
            }
        }

        if preview.count > Config.previewLineCount {
            preview = Array(preview.suffix(Config.previewLineCount))
        }

        return TranscriptInfo(
            path: path,
            title: title,
            lastPrompt: lastPrompt,
            permissionMode: permissionMode,
            hasPendingTool: !pending.isEmpty,
            pendingToolNames: Array(pending.values),
            lastActivity: mtime,
            preview: preview
        )
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
    /// Flattens a message to a single line so it fits a tile row.
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
