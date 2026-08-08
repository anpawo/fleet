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

    @discardableResult
    static func focus(session: Session) -> Bool {
        let host = ProcessScanner.hostApplication(of: session.proc.pid)?.app
        let bundleID = host?.bundleIdentifier ?? ""
        let tty = session.proc.tty

        // Selecting the tab and raising the app are separate problems. AppleScript is the only
        // way to do the first, and it is the part that can be denied by permission; the second
        // always works. So do both, rather than treating the script as all-or-nothing.
        switch bundleID {
        case "com.apple.Terminal":
            runScript(appleTerminalScript(tty: tty), what: "Terminal tab \(tty)")
        case "com.googlecode.iterm2":
            runScript(iTermScript(tty: tty), what: "iTerm2 session \(tty)")
        default:
            break   // terminal without tab-level scripting; raising the app is all we can do
        }

        guard let host else {
            NSLog("Fleet: no host application found for pid \(session.proc.pid)")
            return false
        }
        let ok = host.activate(options: [.activateAllWindows])
        NSLog("Fleet: activated \(bundleID) for pid \(session.proc.pid) -> \(ok)")
        return ok
    }

    /// Returns true when the script found and selected the tab.
    @discardableResult
    private static func runScript(_ source: String, what: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple events", i.e. the Automation permission
            // was never granted or was reset — which it is by a rename, since approval is
            // recorded against the bundle identifier.
            NSLog("Fleet: could not raise \(what): \(error)")
            return false
        }
        guard result.stringValue == "ok" else {
            NSLog("Fleet: no match for \(what)")
            return false
        }
        return true
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
