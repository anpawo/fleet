import AppKit

/// Thin wrapper so ProcessScanner can stay AppKit-agnostic.
struct NSRunningApplicationBox {
    let app: NSRunningApplication

    static func app(forPID pid: pid_t) -> NSRunningApplicationBox? {
        guard let running = NSRunningApplication(processIdentifier: pid),
              running.activationPolicy == .regular else { return nil }
        return NSRunningApplicationBox(app: running)
    }
}

/// Brings the terminal hosting a session to the front, selecting the exact tab where possible.
///
/// Every session has a distinct TTY, and Terminal.app and iTerm2 both expose a tab's `tty` to
/// AppleScript, so the right tab can be raised rather than just the app. Terminals without that
/// scripting surface fall back to activating the application.
@MainActor
enum TerminalFocus {

    static func focus(session: Session) {
        let host = ProcessScanner.hostApplication(of: session.proc.pid)?.app
        let bundleID = host?.bundleIdentifier ?? ""

        if let tty = session.proc.tty {
            switch bundleID {
            case "com.apple.Terminal":
                if runScript(appleTerminalScript(tty: tty)) { return }
            case "com.googlecode.iterm2":
                if runScript(iTermScript(tty: tty)) { return }
            default:
                break   // terminal without tab-level scripting; activate the app instead
            }
        }

        host?.activate(options: [.activateAllWindows])
    }

    /// Returns true when the script found and raised the tab.
    private static func runScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("ClaudeFleet: AppleScript failed: \(error)")
            return false
        }
        return result.stringValue == "ok"
    }

    private static func appleTerminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            set frontmost of w to true
                            activate
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }
}
