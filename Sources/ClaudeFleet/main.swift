import AppKit

/// Background agent. No dock icon, no menu bar item — it only ever surfaces as the panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
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
                  + "\(s.dirName)  pid=\(s.proc.pid)  tty=\(s.proc.tty ?? "—")  "
                  + String(format: "cpu=%.1f%%", s.cpuPercent))
            print("      path:  \(s.displayPath)")
            print("      topic: \(s.topic)")
            print("      file:  \(file)")
            if let t = s.transcript, t.hasPendingTool {
                print("      pending: \(t.pendingToolNames.joined(separator: ", "))")
            }
            print("")
        }
        print(String(format: "idle: %.0fs (threshold %.0fs)",
                     IdleWatcher.idleSeconds(), Config.idleThreshold))
        exit(0)
    }
}

// Optional override: --idle <seconds>
if let i = CommandLine.arguments.firstIndex(of: "--idle"),
   i + 1 < CommandLine.arguments.count,
   let seconds = TimeInterval(CommandLine.arguments[i + 1]) {
    MainActor.assumeIsolated { Config.idleThreshold = max(5, seconds) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication does not retain its delegate.
    objc_setAssociatedObject(app, "ClaudeFleetDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
