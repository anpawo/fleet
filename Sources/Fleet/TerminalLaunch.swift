import AppKit

/// Starts a *new* Claude Code session in a terminal window, optionally on a desktop of its own.
///
/// The counterpart to `TerminalFocus`, which raises a session that already exists. Scripting
/// Bridge is no help here — there is no running process to point it at — so this is
/// `NSAppleScript`, which is also the only way to ask a terminal to open a window and type
/// into it. The Automation permission it needs is the same one tile clicks already use.
@MainActor
enum TerminalLaunch {

    /// Opens a terminal in `directory` and starts `claude` with `prompt` as its first turn.
    ///
    /// Returns whether the *session* started. Sending it to its own desktop is a bonus on top,
    /// and deliberately not part of this answer: a placement that fails still leaves a working
    /// session on the current desktop, which is worth far more than where it sits.
    @discardableResult
    static func startSession(in directory: String, prompt: String) -> Bool {
        // An empty prompt means "just open a session here" — `claude ''` would be handed an
        // empty first turn instead, which is not the same request.
        let start = prompt.isEmpty ? "claude" : "claude \(shellQuote(prompt))"
        return open(command: "cd \(shellQuote(directory)) && \(start)")
    }

    /// Opens a terminal in `directory` with nothing running in it — the panel's `+`.
    ///
    /// A bare shell rather than a session: the button is there for the work you have not
    /// decided on yet, and `claude` is one word away once you are in the window.
    @discardableResult
    static func openTerminal(in directory: String) -> Bool {
        open(command: "cd \(shellQuote(directory))")
    }

    private static func open(command: String) -> Bool {
        let iTerm = preferITerm()
        let bundleID = iTerm ? "com.googlecode.iterm2" : "com.apple.Terminal"
        let script = iTerm ? itermScript(command) : terminalScript(command)

        // Taken before the window exists, so the one that turns up afterwards can be told apart
        // from the ones that were already there.
        let before = Config.openInOwnDesktop ? Desktop.windows(ofBundle: bundleID) : []

        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return false }
        apple.executeAndReturnError(&error)
        if let error {
            NSLog("Fleet: could not launch a session — \(error)")
            return false
        }

        if Config.openInOwnDesktop, Desktop.accessibilityTrusted() {
            Desktop.sendNewWindowToOwnDesktop(bundleID: bundleID, notIn: before)
        }
        return true
    }

    /// Whichever terminal the user actually lives in. Checked by what is running rather than
    /// by a preference: someone with iTerm2 open is not expecting a Terminal.app window.
    private static func preferITerm() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }
    }

    // MARK: - Opening the window

    private static func terminalScript(_ command: String) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleQuote(command))
        end tell
        """
    }

    private static func itermScript(_ command: String) -> String {
        """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(appleQuote(command))
            end tell
        end tell
        """
    }

    // MARK: - Quoting

    /// Single quotes with the one escape POSIX shells allow inside them. The prompt is
    /// dictated speech, so it routinely contains apostrophes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal: backslashes first, then quotes, or the escaping escapes
    /// its own escapes.
    private static func appleQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
