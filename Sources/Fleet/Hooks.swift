import Foundation

/// What Claude Code itself says each session is doing.
///
/// Everything else in Fleet *infers* state from a transcript: a tool call with no result is
/// either work in flight or a prompt on your screen, a silence is either a model thinking or a
/// question you have not answered, and the file looks the same either way. Those inferences are
/// wrong often enough to matter — a session that had finished and showed red is a session you
/// do not go back to.
///
/// Claude Code has the answer and will hand it over: hooks fire on the transitions themselves.
/// `Stop` means the turn is over, `Notification` means it is blocked on you, `UserPromptSubmit`
/// and the tool hooks mean it is working. Each one writes a single small file naming the state
/// and when it was set, and Fleet reads that instead of guessing.
///
/// The transport is a file per session rather than a socket because hooks are separate short
/// processes that must not block the session: a write to a tmpfile and a rename is the whole
/// cost, and Fleet reads whatever is there whenever it happens to refresh.
enum Hooks {

    /// Where the hook script and the state it writes live.
    static let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/fleet")
    static var scriptPath: String { (home as NSString).appendingPathComponent("session-state.sh") }
    static var stateDirectory: String { (home as NSString).appendingPathComponent("state") }
    static let settingsPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/settings.json")

    /// State files older than this belong to sessions that died without a `SessionEnd` — a
    /// crash, a killed terminal — and are cleaned up rather than left to answer for a session
    /// id that will never come back.
    private static let staleAfter: TimeInterval = 7 * 24 * 3600

    // MARK: - Reading

    struct Record {
        var state: SessionState
        /// When the hook fired, which is what decides whether it or the transcript is the more
        /// recent evidence.
        var at: Date
    }

    /// What the hooks last said about `sessionID` — the transcript's file name without its
    /// extension, which is the same id Claude Code passes to a hook.
    static func record(sessionID: String) -> Record? {
        let path = (stateDirectory as NSString).appendingPathComponent(sessionID + ".json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["state"] as? String,
              let at = obj["at"] as? Double else { return nil }

        let state: SessionState
        switch name {
        case "ready": state = .ready
        case "awaiting": state = .awaitingAnswer
        case "running": state = .running
        default: return nil
        }
        return Record(state: state, at: Date(timeIntervalSince1970: at))
    }

    /// Whether the hooks are installed and writing. Checked for the panel's own diagnostics —
    /// the state read above degrades on its own when they are not.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: scriptPath) && settingsMention()
    }

    private static func settingsMention() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Deletes state left behind by sessions that are gone. Cheap enough to run at launch and
    /// pointless more often than that.
    static func prune() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: stateDirectory) else { return }
        for name in names where name.hasSuffix(".json") {
            let path = (stateDirectory as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Installing

    /// How Fleet's own hook entries are recognised in settings.json, so installing twice
    /// replaces them instead of stacking another copy on every run.
    private static let marker = "fleet/session-state.sh"

    /// Which event means what. The two the whole thing is for are `Stop` — the turn is over,
    /// which is the state Fleet used to get wrong — and `Notification`, which fires exactly
    /// when a session is blocked on you.
    private static let events: [(event: String, argument: String)] = [
        ("UserPromptSubmit", "running"),
        ("PreToolUse", "running"),
        ("PostToolUse", "running"),
        ("Notification", "awaiting"),
        ("Stop", "ready"),
        ("SessionEnd", "end"),
    ]

    enum InstallError: LocalizedError {
        case settingsUnreadable(String)
        case settingsNotAnObject

        var errorDescription: String? {
            switch self {
            case .settingsUnreadable(let why): return "Could not read ~/.claude/settings.json: \(why)"
            case .settingsNotAnObject: return "~/.claude/settings.json is not a JSON object."
            }
        }
    }

    /// Writes the hook script and points Claude Code's user settings at it. Idempotent: it
    /// rewrites its own entries and leaves every other hook alone.
    ///
    /// The previous settings file is copied next to itself first. This edits a file the user
    /// did not write and cannot easily reconstruct, so there is a copy of it before we touch it.
    @discardableResult
    static func install() throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.settingsNotAnObject
            }
            settings = obj
            let backup = settingsPath + ".fleet-backup"
            try? fm.removeItem(atPath: backup)
            try? fm.copyItem(atPath: settingsPath, toPath: backup)
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for (event, argument) in events {
            // Every other matcher group for this event is kept as it is; only the group Fleet
            // wrote last time is replaced.
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.removeAll { group in
                let commands = (group["hooks"] as? [[String: Any]]) ?? []
                return commands.contains {
                    ($0["command"] as? String)?.contains(marker) == true
                }
            }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": "sh \"$HOME/.claude/fleet/session-state.sh\" \(argument)",
                    "timeout": 5,
                ]],
            ])
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        prune()
        return settingsPath
    }

    /// Removes Fleet's hook entries again, leaving the rest of settings.json alone.
    @discardableResult
    static func uninstall() throws -> Bool {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: settingsPath),
              var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return false }

        var removed = false
        for (event, groups) in hooks {
            guard var groups = groups as? [[String: Any]] else { continue }
            let before = groups.count
            groups.removeAll { group in
                let commands = (group["hooks"] as? [[String: Any]]) ?? []
                return commands.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if groups.count != before { removed = true }
            hooks[event] = groups
        }
        guard removed else { return false }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        try? fm.removeItem(atPath: scriptPath)
        return true
    }

    /// The hook itself: POSIX sh, no interpreter to start and no dependency to install, because
    /// it runs on every tool call of every session.
    ///
    /// The session id is pulled out with `sed` rather than a JSON parser for the same reason.
    /// It is a UUID in a field Claude Code has always written, and a miss costs nothing: the
    /// file is not updated and Fleet falls back to reading the transcript, exactly as it does
    /// for a session that started before the hooks existed.
    private static let script = """
    #!/bin/sh
    # Written by Fleet — do not edit; `fleet --install-hooks` overwrites this file.
    #
    # Records what a Claude Code session is doing, so Fleet's panel can show the state Claude
    # Code reports instead of one inferred from the transcript. Called with the state the event
    # means: running, awaiting, ready, or end.
    set -u
    state="${1:-}"
    dir="$HOME/.claude/fleet/state"
    input=$(cat)

    # "session_id":"<uuid>" — the same id that names the session's transcript file.
    sid=$(printf '%s' "$input" | sed -n \\
        's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([0-9a-fA-F-]\\{8,\\}\\)".*/\\1/p' | head -1)
    [ -n "$sid" ] || exit 0

    if [ "$state" = "end" ]; then
        rm -f "$dir/$sid.json"
        exit 0
    fi

    # A Notification is usually a permission prompt — the session is blocked on you. The other
    # one it fires for is "you have been idle a while", which means the opposite: the turn is
    # long over and it is waiting for a new prompt.
    if [ "$state" = "awaiting" ]; then
        case "$input" in
            *"waiting for your input"*) state="ready" ;;
        esac
    fi

    mkdir -p "$dir"
    tmp="$dir/$sid.json.$$"
    printf '{"state":"%s","at":%s}\\n' "$state" "$(date +%s)" > "$tmp" && mv "$tmp" "$dir/$sid.json"
    exit 0

    """
}
