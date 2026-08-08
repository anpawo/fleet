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

/// Background agent. No dock icon, no menu bar item — it only ever surfaces as the panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()

        DistributedNotificationCenter.default().addObserver(
            forName: ShowRequest.name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.toggleOnDemand() }
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
            print("")
        }
        print(String(format: "idle: %.0fs (threshold %.0fs)",
                     IdleWatcher.idleSeconds(), Config.idleThreshold))
        exit(0)
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
        controller.injectSessions(registry.refresh())

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
