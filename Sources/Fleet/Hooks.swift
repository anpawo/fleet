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
        /// The hook's own ancestry, nearest first, which is what ties this record to a live
        /// process — see `SessionRegistry.bindFromHooks`. Empty for records written by a hook
        /// script from before Fleet recorded it.
        var pids: [pid_t]
        /// The transcript Claude Code was writing when the hook fired. The session id names a
        /// conversation, but only this says which *file* it is in, and `/clear` moves it.
        var transcriptPath: String?
    }

    /// What the hooks last said about `sessionID` — the transcript's file name without its
    /// extension, which is the same id Claude Code passes to a hook.
    static func record(sessionID: String) -> Record? {
        record(atPath: (stateDirectory as NSString).appendingPathComponent(sessionID + ".json"))
    }

    /// Every session the hooks currently have something to say about, keyed by session id.
    static func records() -> [String: Record] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDirectory)
        else { return [:] }
        var out: [String: Record] = [:]
        for name in names where name.hasSuffix(".json") {
            let path = (stateDirectory as NSString).appendingPathComponent(name)
            guard let record = record(atPath: path) else { continue }
            out[(name as NSString).deletingPathExtension] = record
        }
        return out
    }

    private static func record(atPath path: String) -> Record? {
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
        let pids = ((obj["pids"] as? String) ?? "").split(separator: ",").compactMap { pid_t($0) }
        let transcript = (obj["transcript"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Record(state: state, at: Date(timeIntervalSince1970: at),
                      pids: pids, transcriptPath: transcript)
    }

    /// Where Fleet tells the hooks — and through them every Claude Code session on the
    /// machine — how the machine itself is doing.
    static var machinePath: String { (home as NSString).appendingPathComponent("machine.json") }

    /// The one thing that travels the other way: Fleet writing, the sessions reading.
    ///
    /// A file rather than anything cleverer for the same reason the state files are files: a
    /// hook is a short-lived shell script that must not block a session, and `cat` is the
    /// whole protocol. It carries a timestamp because a Fleet that dies while the machine is
    /// thrashing would otherwise leave every session nagged forever by a file nobody updates.
    /// The button on the panel: every Claude Code session on this machine is asked to stop
    /// what it is doing, at its next tool call.
    ///
    /// Not a signal. A `SIGINT` to a session would be read by its terminal as a keystroke or
    /// kill it outright, and the whole point is to end a *turn*, not a process. The hooks
    /// already run inside every session and can answer `continue: false`, which is the
    /// supported way to say stop — Claude Code halts the turn and shows the reason.
    static func requestAgentStop() {
        var json = (machineState() ?? [:])
        json["stop"] = Int(Date().timeIntervalSince1970)
        write(json)
        NSLog("Fleet: asked every session to stop")
    }

    private static func machineState() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: machinePath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: machinePath), options: .atomic)
    }

    static func writeMachineState(struggling: Bool, reason: String, hogs: [Hog]) {
        let names = hogs.prefix(4)
            .map { "\($0.name) \($0.sizeLabel)" }
            .joined(separator: ", ")
        var json: [String: Any] = [
            "struggling": struggling,
            "reason": reason,
            "hogs": names,
            "at": Int(Date().timeIntervalSince1970),
        ]
        // A stop pressed a moment ago outlives the verdict that prompted it: the machine
        // recovering one second later must not cancel a stop the sessions have not yet read.
        if let stop = machineState()?["stop"] as? Int,
           Date().timeIntervalSince1970 - Double(stop) < 300 {
            json["stop"] = stop
        }
        write(json)
    }

    /// Bumped whenever the script starts recording something Fleet relies on. An older script
    /// still works — every field is optional on the reading side — but it costs the session
    /// pairing the hooks are there to make exact, so it counts as not installed and the menu
    /// offers to bring it up to date.
    static let version = 2

    /// Whether the hooks are installed and writing. Checked for the panel's own diagnostics —
    /// the state read above degrades on its own when they are not.
    static var isInstalled: Bool { installedVersion == version && settingsMention() }

    /// Installed, but written by an older Fleet: worth a different word in the menu.
    static var isOutdated: Bool {
        guard let installed = installedVersion else { return false }
        return installed != version
    }

    private static var installedVersion: Int? {
        guard FileManager.default.isExecutableFile(atPath: scriptPath),
              let text = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        else { return nil }
        // Absent from the scripts written before versioning existed, which are version 1.
        guard let line = text.split(separator: "\n").first(where: {
            $0.hasPrefix("# fleet-hook-version:")
        }) else { return 1 }
        return Int(line.dropFirst("# fleet-hook-version:".count).trimmingCharacters(in: .whitespaces))
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
    # fleet-hook-version: 4
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
        rm -f "$dir/$sid.json" "$dir/$sid.nudge" "$dir/$sid.stopped"
        exit 0
    fi

    # The one message that travels towards the session rather than away from it: when Fleet
    # has decided the machine has stopped keeping up, the agent is told so in its own context,
    # at the next tool result or prompt. It is told, not stopped — a run that is halfway
    # through something expensive is the agent's call, not this script's.
    #
    # Rate-limited per session, because PostToolUse fires on every single tool call and an
    # instruction repeated forty times in a row is an instruction that crowds out the work.
    advise() {
        machine="$HOME/.claude/fleet/machine.json"
        [ -f "$machine" ] || return 0
        payload=$(cat "$machine" 2>/dev/null) || return 0
        case "$payload" in *'"struggling":true'*) ;; *) return 0 ;; esac

        # Only the two events whose stdout Claude Code feeds back to the model.
        event=$(printf '%s' "$input" | sed -n \\
            's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\\([A-Za-z]*\\)".*/\\1/p' | head -1)
        case "$event" in PostToolUse | UserPromptSubmit ) ;; * ) return 0 ;; esac

        now=$(date +%s)
        reason=$(printf '%s' "$payload" | sed -n 's/.*"reason":"\\([^"]*\\)".*/\\1/p' | head -1)
        # A verdict nobody has refreshed in five minutes is from a Fleet that is no longer
        # running. Stale advice about a machine is worse than none.
        at=$(printf '%s' "$payload" | sed -n 's/.*"at":\\([0-9]*\\).*/\\1/p' | head -1)
        [ -n "${at:-}" ] && [ $((now - at)) -lt 300 ] || return 0

        # The panel's stop button. One per session per press: the stamp records which stop
        # this session has already honoured, so a run started after it is not cut down by a
        # press from ten minutes ago.
        stop=$(printf '%s' "$payload" | sed -n 's/.*"stop":\\([0-9]*\\).*/\\1/p' | head -1)
        if [ -n "${stop:-}" ] && [ $((now - stop)) -lt 300 ]; then
            honoured=0
            [ -f "$dir/$sid.stopped" ] && honoured=$(cat "$dir/$sid.stopped" 2>/dev/null || echo 0)
            if [ "$stop" != "$honoured" ]; then
                mkdir -p "$dir" && echo "$stop" > "$dir/$sid.stopped"
                printf '{"continue":false,"stopReason":"Fleet stopped this session: %s. '
                printf 'Nothing is lost — say go when the machine has room again."}\\n' "$reason"
                return 0
            fi
        fi

        stamp="$dir/$sid.nudge"
        if [ -f "$stamp" ]; then
            last=$(cat "$stamp" 2>/dev/null || echo 0)
            [ $((now - last)) -ge 300 ] || return 0
        fi
        mkdir -p "$dir" && echo "$now" > "$stamp"

        hogs=$(printf '%s' "$payload" | sed -n 's/.*"hogs":"\\([^"]*\\)".*/\\1/p' | head -1)
        note="Fleet: this Mac has stopped keeping up ($reason). Heaviest processes right now: \\
    ${hogs:-unknown}. Wind down what you can until it recovers: no new subagents, no new \\
    builds, servers or watchers, finish or checkpoint what is already in flight, and read one \\
    file at a time rather than fanning out. If the heavy thing is the task the user asked for, \\
    say so in one line and let them decide."
        note=$(printf '%s' "$note" | tr -s ' \\n' ' ')
        printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},' \\
            "$event" "$note"
        printf '"systemMessage":"Fleet: machine under strain - %s"}\\n' "$reason"
    }
    advise

    # Which transcript this session is writing, and which process is writing it.
    #
    # Fleet has to pair a live process with a file, and neither side says so outright: it
    # matches on the working directory and on which transcript appeared just after the process
    # started. That pairing survives until the session changes files underneath it — `/clear`
    # and a compaction both start a new transcript in the same process — and from then on the
    # panel reads a conversation that ended, which always looks finished.
    #
    # The hook is the one place both facts are known at once: the payload names the file, and
    # the session is this script's own parent. It is usually the immediate parent, but a hook
    # invoked through a wrapper shell would sit one further down, so a short ancestry is
    # recorded and Fleet takes the first entry that is a session it can see. Two levels up is
    # as far as this is worth one extra `ps`.
    path=$(printf '%s' "$input" | sed -n \\
        's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
    pids="$PPID"
    up=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
    case "${up:-}" in
        '' | 0 | 1 | *[!0-9]* ) ;;
        * ) pids="$pids,$up" ;;
    esac

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
    printf '{"state":"%s","at":%s,"pids":"%s","transcript":"%s"}\\n' \\
        "$state" "$(date +%s)" "$pids" "$path" > "$tmp" && mv "$tmp" "$dir/$sid.json"
    exit 0

    """
}
