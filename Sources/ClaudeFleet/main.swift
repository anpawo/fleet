import AppKit
import SwiftUI

/// Background agent. No dock icon, no menu bar item — it only ever surfaces as the panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        if CommandLine.arguments.contains("--demo") {
            controller.forceShow()
        }
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication does not retain its delegate.
    objc_setAssociatedObject(app, "ClaudeFleetDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
