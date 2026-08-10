import AppKit
import ScriptingBridge

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
/// their scripting interface, so the right tab can be raised rather than just the app.
///
/// Scripting Bridge rather than `NSAppleScript`, because a script says `tell application
/// "Terminal"` and macOS resolves that to *one* process. Two instances of the same terminal can
/// be running at once — and then every session hosted by the other instance silently misses,
/// leaving us to activate the app and land on whatever tab happened to be frontmost. Scripting
/// Bridge can be pointed at a pid, and we already know the exact pid hosting the session.
@MainActor
enum TerminalFocus {

    @discardableResult
    static func focus(session: Session) -> Bool {
        let host = ProcessScanner.hostApplication(of: session.proc.pid)?.app
        let bundleID = host?.bundleIdentifier ?? ""
        let tty = session.proc.tty

        // Selecting the tab and raising the app are separate problems. Only the first can be
        // denied by the Automation permission; the second always works. So do both, rather
        // than treating the tab selection as all-or-nothing.
        if let host {
            switch bundleID {
            case "com.apple.Terminal":
                select(tty: tty, inTerminal: host.processIdentifier)
            case "com.googlecode.iterm2":
                select(tty: tty, iniTerm: host.processIdentifier)
            default:
                break   // terminal without tab-level scripting; raising the app is all we can do
            }
        }

        guard let host else {
            NSLog("Fleet: no host application found for pid \(session.proc.pid)")
            return false
        }
        let ok = host.activate(options: [.activateAllWindows])
        NSLog("Fleet: activated \(bundleID) for pid \(session.proc.pid) -> \(ok)")
        return ok
    }

    /// The scripting connection to one specific process.
    ///
    /// Scripting Bridge blocks the calling thread waiting for a reply, and this runs on the
    /// main actor, so the timeout matters: a wedged terminal must cost us a beat, not the UI.
    private static func app(pid: pid_t) -> SBApplication? {
        guard let app = SBApplication(processIdentifier: pid) else {
            NSLog("Fleet: no scripting connection to pid \(pid)")
            return nil
        }
        app.timeout = 120        // ticks, i.e. 2 seconds
        return app
    }

    /// Terminal.app: window -> tab, where the tab carries `tty`.
    @discardableResult
    private static func select(tty: String, inTerminal pid: pid_t) -> Bool {
        guard let app = app(pid: pid),
              let windows = app.value(forKey: "windows") as? SBElementArray else { return false }

        for case let window as SBObject in windows {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for case let tab as SBObject in tabs {
                guard tab.value(forKey: "tty") as? String == tty else { continue }
                tab.setValue(true, forKey: "selected")
                // Index 1 is the front of Terminal's window ordering; without this the right
                // tab is selected inside a window that stays behind another one.
                window.setValue(1, forKey: "index")
                return true
            }
        }
        NSLog("Fleet: no tab with \(tty) in Terminal \(pid)")
        return false
    }

    /// iTerm2: window -> tab -> session, and it is the session that carries `tty`. Selection is
    /// a command rather than a property, and has to be applied at each level.
    @discardableResult
    private static func select(tty: String, iniTerm pid: pid_t) -> Bool {
        guard let app = app(pid: pid),
              let windows = app.value(forKey: "windows") as? SBElementArray else { return false }

        let selectCmd = NSSelectorFromString("select")
        for case let window as SBObject in windows {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for case let tab as SBObject in tabs {
                guard let sessions = tab.value(forKey: "sessions") as? SBElementArray else {
                    continue
                }
                for case let session as SBObject in sessions {
                    guard session.value(forKey: "tty") as? String == tty else { continue }
                    for target in [window, tab, session] where target.responds(to: selectCmd) {
                        target.perform(selectCmd)
                    }
                    return true
                }
            }
        }
        NSLog("Fleet: no session with \(tty) in iTerm2 \(pid)")
        return false
    }
}
