import AppKit
import ApplicationServices
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

        // Activation only promises the app is frontmost. If its window is on another desktop —
        // or on another display running its own Spaces, which is where this was found — you are
        // not taken there, and the click looks like it did nothing at all. Raising the window
        // is what crosses that gap. It runs after activation on purpose: the focused window is
        // how the right one is identified, and until the app is frontmost that is somebody
        // else's window.
        if Desktop.accessibilityTrusted() {
            Desktop.raise(pid: host.processIdentifier)
        }
        return ok
    }

    /// What is on screen in the tab hosting this session, or nil when we cannot see it.
    ///
    /// The one signal that only exists here. When a request fails, Claude Code prints
    /// "API error · Retrying in 4s · attempt 3/10" and writes *nothing at all* to the
    /// transcript — no entry, no hook, no CPU — so from the file the session is indis-
    /// tinguishable from one sitting on a question waiting for an answer. The screen is the
    /// only place the difference is written down, and Fleet is already in this file talking to
    /// the same tab by the same tty.
    ///
    /// Costs a Scripting Bridge round trip on the main thread, so the caller is expected to ask
    /// rarely and about few sessions — see `Config.terminalReadInterval`.
    static func visibleText(pid: pid_t, tty: String, cwd: String) -> String? {
        guard let host = ProcessScanner.hostApplication(of: pid)?.app else { return nil }
        switch host.bundleIdentifier ?? "" {
        case "com.apple.Terminal":
            return contents(tty: tty, inTerminal: host.processIdentifier)
        case "com.googlecode.iterm2":
            return contents(tty: tty, iniTerm: host.processIdentifier)
        default:
            return contents(cwd: cwd, viaAccessibility: host.processIdentifier)
        }
    }

    /// Terminal.app: `contents` is the visible screen, `history` the whole scrollback. The
    /// visible screen is the one that matters — the status line we are after is pinned to the
    /// bottom of it, and the scrollback is megabytes.
    private static func contents(tty: String, inTerminal pid: pid_t) -> String? {
        guard let app = app(pid: pid),
              let windows = app.value(forKey: "windows") as? SBElementArray else { return nil }

        for case let window as SBObject in windows {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for case let tab as SBObject in tabs
            where tab.value(forKey: "tty") as? String == tty {
                return tab.value(forKey: "contents") as? String
            }
        }
        return nil
    }

    /// iTerm2 hangs the text off the session rather than the tab, and calls it `text`.
    private static func contents(tty: String, iniTerm pid: pid_t) -> String? {
        guard let app = app(pid: pid),
              let windows = app.value(forKey: "windows") as? SBElementArray else { return nil }

        for case let window as SBObject in windows {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for case let tab as SBObject in tabs {
                guard let sessions = tab.value(forKey: "sessions") as? SBElementArray else {
                    continue
                }
                for case let session as SBObject in sessions
                where session.value(forKey: "tty") as? String == tty {
                    return session.value(forKey: "text") as? String
                }
            }
        }
        return nil
    }

    /// Terminals with no scripting interface at all — Ghostty, and most of the newer ones —
    /// through the Accessibility API instead. Without this a Ghostty session has no screen to
    /// read, and a long turn that writes nothing is indistinguishable from a question waiting
    /// for an answer: the tile turns blue on a session that is working.
    ///
    /// Two things Ghostty does differently. It publishes the screen as the `AXTextArea` inside
    /// its window, which is exactly what we want — but it publishes no `AXWindows` at all: the
    /// attribute comes back an empty array, and `AXFocusedWindow` is the only way in. That is
    /// the app's own last-focused window, which does not require the app to be frontmost, so
    /// one window per terminal is readable and the rest are invisible.
    ///
    /// Which makes identifying the session the whole problem, since there is no tty here to
    /// match on. `AXDocument` is the surface's working directory, so it can be compared with
    /// the one the session runs in — and a mismatch is answered with nil rather than a guess:
    /// this is the second opinion that overrides "waiting for you", and another window's screen
    /// would silence a question that really is on yours.
    private static func contents(cwd: String, viaAccessibility pid: pid_t) -> String? {
        guard Desktop.accessibilityTrusted(prompt: false),
              let window = Desktop.focusedWindow(of: AXUIElementCreateApplication(pid)),
              let document = string(window, kAXDocumentAttribute),
              let surface = URL(string: document)?.standardizedFileURL.path,
              surface == URL(fileURLWithPath: cwd).standardizedFileURL.path else { return nil }
        return screenText(in: window)
    }

    /// The first text area in the window, which for a terminal is the screen itself.
    private static func screenText(in element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 8 { return nil }
        if string(element, kAXRoleAttribute) == "AXTextArea" {
            return string(element, kAXValueAttribute)
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let text = screenText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
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
