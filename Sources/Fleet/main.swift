import AppKit
import SwiftUI

/// The "show the panel now" request, used by every manual trigger: opening Fleet.app from
/// Spotlight, the `fleet` command, or a second `open` of the bundle. Distributed rather than
/// local because the request is nearly always raised by a *different* process than the
/// resident one that owns the panel.
enum ShowRequest {
    static let name = Notification.Name("com.mr.fleet.show")

    static func post() {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// Background agent. No dock icon; its only permanent presence is the menu bar plane, and
/// everything else it has to say goes in the panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()

        // ⌘⌥L raises the panel, the same way ⌘⌥T is wired to Terminal. Deliberately *not* a
        // toggle: "bring it to the front" should be idempotent, and Esc already dismisses.
        HotKey.register { [weak controller] in
            MainActor.assumeIsolated { controller?.forceShow(announceEmpty: true) }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: ShowRequest.name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.toggleOnDemand() }
        }

        if let f = CommandLine.arguments.firstIndex(of: "--fake"),
           f + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[f + 1]) {
            controller.pretendFleet = DemoFleet.sessions(n)
        }

        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--show") {
            controller.toggleOnDemand()
        }
    }

    /// Launching an already-running bundle (Spotlight, Dock, `open`) arrives here instead of
    /// starting a second process, so this is the usual path for a manual trigger.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.toggleOnDemand()
        return true
    }
}

// `--install-hooks` points Claude Code at the state hook, which is what makes a tile's colour
// something Claude Code reported rather than something Fleet inferred. Separate from launching
// the app because it edits ~/.claude/settings.json, and a file the user owns is not something
// an app should quietly rewrite the first time it starts.
if CommandLine.arguments.contains("--install-hooks") {
    do {
        let path = try Hooks.install()
        print("Installed the session-state hooks into \(path)")
        print("  script: \(Hooks.scriptPath)")
        print("  state:  \(Hooks.stateDirectory)/<session-id>.json")
        print("  backup: \(path).fleet-backup")
        print("")
        print("Sessions already running keep the inferred state until they are restarted.")
    } catch {
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        print("failed: \(why)")
        exit(1)
    }
    exit(0)
}

// The way back out, so installing is not a one-way door.
if CommandLine.arguments.contains("--uninstall-hooks") {
    do {
        let removed = try Hooks.uninstall()
        print(removed ? "Removed Fleet's hooks from \(Hooks.settingsPath)"
                      : "Fleet's hooks were not installed.")
    } catch {
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        print("failed: \(why)")
        exit(1)
    }
    exit(0)
}

// `--scan` prints what the app currently sees and exits: a headless way to check session
// discovery, transcript binding and state colours without waiting to go idle.
if CommandLine.arguments.contains("--scan") {
    MainActor.assumeIsolated {
        let registry = SessionRegistry()
        _ = registry.refresh()               // first pass seeds the CPU baseline
        Thread.sleep(forTimeInterval: 0.6)
        let sessions = registry.refresh()

        guard !sessions.isEmpty else {
            print("No Claude Code sessions running.")
            exit(0)
        }
        print("\(sessions.count) session(s):\n")
        for s in sessions {
            let file = s.transcript.map { ($0.path as NSString).lastPathComponent } ?? "—"
            print("  [\(s.state.label.padding(toLength: 9, withPad: " ", startingAt: 0))] "
                  + "\(s.dirName)  pid=\(s.proc.pid)  tty=\(s.proc.tty)  "
                  + String(format: "cpu=%.1f%%", s.cpuPercent))
            print("      path:  \(s.displayPath)")
            print("      topic: \(s.topic)")
            print("      file:  \(file)")
            if let t = s.transcript, t.hasPendingTool {
                print("      pending: \(t.pendingToolNames.joined(separator: ", "))")
            }
            // Which of the two sources the colour above came from. A tile that looks wrong is
            // either a hook that has not fired or an inference that is off, and they are fixed
            // in completely different places.
            let sessionID = ((s.transcript?.path ?? "") as NSString).lastPathComponent
                .replacingOccurrences(of: ".jsonl", with: "")
            if let hook = Hooks.record(sessionID: sessionID) {
                let age = Int(Date().timeIntervalSince(hook.at))
                print("      hook:  \(hook.state.label.lowercased()), \(age)s ago")
            }
            for agent in s.subagents {
                print("      sub-agent: \(agent.kind) — \(agent.task)")
                print("                 \(agent.step ?? "starting…")")
            }
            print("")
        }
        print(String(format: "idle: %.0fs (threshold %.0fs)",
                     IdleWatcher.idleSeconds(), Config.idleThreshold))
        if Hooks.isOutdated {
            print("state hooks are from an older Fleet — sessions are still paired to their "
                  + "transcripts by guesswork. Run `fleet --install-hooks`.")
        } else if !Hooks.isInstalled {
            print("state hooks not installed — colours are inferred from the transcripts. "
                  + "Run `fleet --install-hooks`.")
        }
        if let awake = ScreenWatcher.holdingDisplayAwake() {
            print("display held awake by \"\(awake)\" — the idle trigger is deferred")
        }
        exit(0)
    }
}

// `--parse <transcript.jsonl>` prints what one transcript parses to, without needing the
// session that owns it to be running. The state a tile shows is mostly this parse, and a live
// session is a poor thing to debug against: it will not hold still.
if let i = CommandLine.arguments.firstIndex(of: "--parse"),
   i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    guard let info = TranscriptStore().info(for: path) else {
        print("could not read \(path)")
        exit(1)
    }
    print("title:    \(info.title ?? "—")")
    print("cwd:      \(info.cwd ?? "—")")
    print("turnOpen: \(info.turnOpen)")
    print("pending:  \(info.pendingToolLabels.joined(separator: " | "))")
    for agent in info.subagents {
        let age = Int(Date().timeIntervalSince(agent.lastActivity))
        print("sub-agent \(agent.kind) — \(agent.task)  (last wrote \(age)s ago)")
        print("          \(agent.step ?? "starting…")")
    }
    print("preview:")
    for line in info.preview.suffix(Config.railLineCount) { print("  \(line.text)") }
    exit(0)
}

// `--windows [bundle-id]` lists a terminal's windows on the desktop you are on, and whether
// each has that desktop to itself. The only way to check a placement from outside the app.
if let i = CommandLine.arguments.firstIndex(of: "--windows") {
    let bundle = i + 1 < CommandLine.arguments.count && !CommandLine.arguments[i + 1]
        .hasPrefix("-") ? CommandLine.arguments[i + 1] : "com.apple.Terminal"
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Desktop.accessibilityTrusted()
        let lines = Desktop.describeWindows(ofBundle: bundle)
        print(lines.isEmpty ? "no \(bundle) windows on this desktop"
                            : lines.joined(separator: "\n"))
        exit(0)
    }
}

// `--new-desktop` does what the panel's `+` does: a terminal, on a desktop macOS makes for it.
// `--spaces-bar` takes the other route instead — Mission Control's own `+`, pressed through the
// Dock's accessibility tree — which is the only way to a real, empty Space and the part a macOS
// update can move under us. Worth a flag each: they fail differently.
if CommandLine.arguments.contains("--new-desktop") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--spaces-bar") {
            print("new desktop: \(Spaces.addDesktop(switchingTo: true) ? "ok" : "failed")")
            exit(0)
        }
        print("terminal: \(TerminalLaunch.openTerminal(in: Config.projectRoot) ? "ok" : "failed")")
        // The desktop is given asynchronously, by a poll that outlives this line.
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        for line in Desktop.describeWindows(ofBundle: "com.apple.Terminal") { print("  \(line)") }
        exit(0)
    }
}

// `--start <directory> ["<prompt>"]` opens a session the way the panel does — new window, its
// own desktop — without going through the classifier. The placement is the part that breaks,
// and typing a sentence into the panel every time is a poor way to test a window server.
if let i = CommandLine.arguments.firstIndex(of: "--start"),
   i + 1 < CommandLine.arguments.count {
    let directory = CommandLine.arguments[i + 1]
    let prompt = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : ""
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let ok = TerminalLaunch.startSession(in: directory, prompt: prompt)
        print("start in \(directory): \(ok ? "ok" : "failed")")
        // The desktop is given asynchronously — it polls for the new window. Exiting here
        // would kill that before it ran, and the wait has to outlast the poll's own timeout or
        // the interesting case is the one that never gets reported.
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        for line in Desktop.describeWindows(ofBundle: "com.apple.Terminal") { print("  \(line)") }
        exit(ok ? 0 : 1)
    }
}

// `--route "<sentence>"` runs one sentence through the classifier and prints where it would
// go, without starting a session or opening a window. The routing path is otherwise only
// reachable through the panel, which is a poor way to debug a prompt.
if let i = CommandLine.arguments.firstIndex(of: "--route"),
   i + 1 < CommandLine.arguments.count {
    let said = CommandLine.arguments[i + 1]
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: Config.projectRoot))
            ?? []
        do {
            let started = Date()
            let route = try await Claude.classify(said, projects: projects.filter {
                !$0.hasPrefix(".")
            })
            print("kind:    \(route.kind.rawValue)")
            print("project: \(route.project.isEmpty ? "—" : route.project)")
            print("prompt:  \(route.prompt)")
            print(String(format: "took:    %.1fs", Date().timeIntervalSince(started)))
        } catch {
            let why = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            print("failed: \(why)")
        }
    }
    done.wait()
    exit(0)
}

if CommandLine.arguments.contains("--ax-probe") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        print("trusted: \(AXIsProcessTrusted())")
        let index = CommandLine.arguments.firstIndex(of: "--ax-probe")!
        let wanted = index + 1 < CommandLine.arguments.count
            ? pid_t(CommandLine.arguments[index + 1]) : nil
        guard let term = NSWorkspace.shared.runningApplications.first(where: { app in
            if let wanted { return app.processIdentifier == wanted }
            return app.bundleIdentifier == "com.apple.Terminal"
        }) else { print("Terminal not running"); exit(1) }

        let app = AXUIElementCreateApplication(term.processIdentifier)
        print("probing pid \(term.processIdentifier) (\(term.bundleIdentifier ?? "?"))")

        var names: CFArray?
        let nameErr = AXUIElementCopyAttributeNames(app, &names)
        print("app attributes: err=\(nameErr.rawValue) "
              + "\((names as? [String] ?? []).prefix(12).joined(separator: ", "))")

        var systemWide: CFTypeRef?
        let swErr = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                  kAXFocusedApplicationAttribute as CFString,
                                                  &systemWide)
        print("system-wide focused app: err=\(swErr.rawValue)")

        print("all app attributes: \((names as? [String] ?? []).joined(separator: ", "))")

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        var windows = (value as? [AXUIElement]) ?? []
        print("AXWindows: err=\(err.rawValue) count=\(windows.count)")

        var focused: CFTypeRef?
        let fErr = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                                 &focused)
        print("AXFocusedWindow: err=\(fErr.rawValue) present=\(focused != nil)")
        if windows.isEmpty, let focused {
            windows = [focused as! AXUIElement]
        }

        var main: CFTypeRef?
        let mErr = AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &main)
        print("AXMainWindow: err=\(mErr.rawValue) present=\(main != nil)")

        for (n, window) in windows.enumerated() {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            var full: CFTypeRef?
            let fullErr = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full)
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable)
            print("  [\(n)] \(title as? String ?? "?") — AXFullScreen err=\(fullErr.rawValue) "
                  + "value=\(full as? Bool ?? false) settable=\(settable.boolValue)")
        }
        exit(0)
    }
}

// `--launch <directory> [prompt]` runs the session-starting path on its own: a terminal window
// opens, `claude` starts in it, and — with `Config.openInOwnDesktop` on — it is thrown onto a
// desktop of its own. Speaking at the panel is otherwise the only way to reach this, and the
// Accessibility grant it needs cannot be tested from a shell: the permission belongs to the
// app that asks, so it has to be Fleet asking.
if let i = CommandLine.arguments.firstIndex(of: "--launch"),
   i + 1 < CommandLine.arguments.count {
    let directory = (CommandLine.arguments[i + 1] as NSString).expandingTildeInPath
    let prompt = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : ""
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let trusted = AXIsProcessTrusted()
        print("accessibility: \(trusted ? "granted" : "NOT granted — the window will stay on this desktop")")
        let ok = TerminalLaunch.startSession(in: directory, prompt: prompt)
        print("launch \(directory): \(ok ? "ok" : "failed")")
        // Run the loop rather than sleeping on it: the fullscreen step waits for the window
        // to be placed, and it is a main-actor task — a blocked main thread never runs it.
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        exit(ok ? 0 : 1)
    }
}

// `--render <path.png>` draws the panel offscreen. Useful for checking layout without waiting
// to go idle, and for generating the screenshot in the README.
if let i = CommandLine.arguments.firstIndex(of: "--render"),
   i + 1 < CommandLine.arguments.count {
    let outPath = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let registry = SessionRegistry()
        _ = registry.refresh()
        let controller = AppController()
        // `--fake <n>` draws a fleet of n synthetic sessions instead of the live one, which is
        // how the grid's shape is checked at counts you do not have running.
        if let f = CommandLine.arguments.firstIndex(of: "--fake"),
           f + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[f + 1]) {
            controller.injectSessions(DemoFleet.sessions(n))
        } else {
            controller.injectSessions(registry.refresh())
        }

        // The side columns come off the network, and an offscreen render has nobody to wait for
        // them. Waiting by spinning the run loop rather than blocking on it: the fetch lands on
        // the main actor, and a blocked main thread would never let it finish.
        controller.hub.refresh()
        let deadline = Date().addingTimeInterval(8)
        while controller.hub.isConfigured, !controller.hub.loaded,
              controller.hub.failure == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let view = OverlayView(controller: controller, eagerLayout: true)
            .frame(width: 1512, height: 1100)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render failed")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
        exit(0)
    }
}

// `--screen <pid>` prints what Fleet can read off that session's terminal tab, and whether it
// reads as a failed request. The API-error colour depends entirely on this working, and it can
// fail for reasons that are invisible from the panel — a denied Automation permission, a
// terminal without tab-level scripting, a `contents` property that came back empty.
if let i = CommandLine.arguments.firstIndex(of: "--screen"),
   i + 1 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[i + 1]) {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let registry = SessionRegistry()
        guard let session = registry.refresh().first(where: { $0.proc.pid == pid }) else {
            print("no session with pid \(pid)")
            exit(1)
        }
        guard let text = TerminalFocus.visibleText(pid: pid, tty: session.proc.tty) else {
            print("could not read the tab for \(session.dirName) (tty \(session.proc.tty))")
            exit(1)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        print("--- last 8 lines on \(session.dirName) (tty \(session.proc.tty))")
        for line in lines.suffix(8) { print("| \(line)") }
        print("--- reads as a failed request: \(ApiErrorWatch.showsFailure(text))")
        exit(0)
    }
}

// `--focus <pid>` runs just the tab-raising path for one session and reports what happened.
// Clicking a tile is otherwise the only way to exercise it, which makes a silent failure —
// a missing Automation permission, usually — awkward to tell apart from a layout problem.
if let i = CommandLine.arguments.firstIndex(of: "--focus"),
   i + 1 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[i + 1]) {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let registry = SessionRegistry()
        guard let session = registry.refresh().first(where: { $0.proc.pid == pid }) else {
            print("no session with pid \(pid)")
            exit(1)
        }
        let ok = TerminalFocus.focus(session: session)
        print("focus \(session.dirName) (tty \(session.proc.tty)): \(ok ? "ok" : "failed")")
        // Raising the window across a desktop is asynchronous — it polls for the focused window
        // once the app is frontmost. Exiting here would kill it before it ran, and this flag
        // exists precisely to exercise the whole path.
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        exit(ok ? 0 : 1)
    }
}

// Optional override: --idle <seconds>
if let i = CommandLine.arguments.firstIndex(of: "--idle"),
   i + 1 < CommandLine.arguments.count,
   let seconds = TimeInterval(CommandLine.arguments[i + 1]) {
    MainActor.assumeIsolated { Config.idleThreshold = max(5, seconds) }
}

// If a resident copy is already running — normally the LaunchAgent one — this process exists
// only because the user asked to see the panel. Hand the request over and get out of the way,
// so we never end up with two agents scanning in parallel.
if let bundleID = Bundle.main.bundleIdentifier {
    let mine = ProcessInfo.processInfo.processIdentifier
    let resident = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != mine }
    if resident {
        ShowRequest.post()
        // Distributed delivery needs a turn of the run loop before we can safely exit.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication does not retain its delegate.
    objc_setAssociatedObject(app, "FleetDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
