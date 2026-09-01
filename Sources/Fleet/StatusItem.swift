import AppKit
import SwiftUI

/// The menu bar presence: a plain paper plane with a single coloured dot in its bottom-right
/// corner, showing whichever session most wants your attention. This is the only place Fleet is
/// visible when the panel is down, so it doubles as the "yes, it is running" indicator.
@MainActor
final class StatusItemController {

    private let item: NSStatusItem
    private unowned let controller: AppController
    private let dot = NSView()

    private static let dotSize: CGFloat = 4

    /// What the button currently displays. The refresh tick fires every few seconds and almost
    /// never changes the state, so this avoids redrawing the menu bar for nothing.
    private var shown: SessionState??
    /// Same idea for the muted look, which swaps the whole glyph.
    private var shownMuted: Bool?

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.image = Self.planeImage(filled: true)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Fleet — Claude Code sessions"
            install(dot: dot, on: button)
        }
        update(sessions: [])
    }

    /// The dot is a sibling view rather than part of the image on purpose: the plane is a
    /// template, so the menu bar repaints it black or white to match the bar, and anything drawn
    /// into that image would be repainted along with it. A separate layer keeps its own colour
    /// while the plane keeps adapting.
    private func install(dot: NSView, on button: NSStatusBarButton) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            // Placed off the button's centre rather than its leading edge: the button carries
            // several points of padding around the glyph, and anchoring to its edge left the dot
            // floating in the gap looking like a separate menu bar item. The offsets put it in
            // the bottom-left, sitting on the line of the plane's fold rather than square in the
            // corner — so it reads as trailing the plane instead of stuck beside it.
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: -5.5),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 6.5),
        ])
    }

    deinit {
        // `deinit` is nonisolated; the status bar API is main-actor. Hop rather than capture
        // self, which is already gone by the time the block runs.
        let item = self.item
        MainActor.assumeIsolated { NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - Appearance

    func update(sessions: [Session], muted: Bool = false) {
        // A hollow plane while muted: the chord is pressed with nothing on screen, so the menu
        // bar is the only place that can acknowledge it.
        if shownMuted != muted {
            shownMuted = muted
            item.button?.image = Self.planeImage(filled: !muted)
        }
        // Urgency reuses `sortRank` — the same order the tiles use, and the right one here too:
        // "needs you" outranks "ready" (your turn) which outranks "working" (nothing to do yet).
        let top = sessions.min { $0.state.sortRank < $1.state.sortRank }?.state
        guard shown != .some(top) else { return }
        shown = .some(top)

        // Nothing running means no dot at all, leaving a bare plane — the quietest thing the
        // menu bar can show while still saying Fleet is there.
        dot.isHidden = top == nil
        dot.layer?.backgroundColor = top.map { NSColor($0.tint).cgColor }
    }

    /// `paperplane.fill` rather than anything boat-shaped: at 15pt a hull and mast collapse into
    /// a smudge, while the plane stays a clean silhouette. Template mode hands the menu bar
    /// control of its colour, so it inverts correctly in light and dark.
    private static func planeImage(filled: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: filled ? "paperplane.fill" : "paperplane",
                            accessibilityDescription: "Fleet")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: - Interaction

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            controller.toggleOnDemand()
        }
    }

    /// Attaching a menu to the item permanently would swallow left clicks, so the menu is only
    /// popped for the right button and detached again straight after.
    private func showMenu() {
        let menu = NSMenu()

        let sessions = controller.sessions
        if sessions.isEmpty {
            menu.addItem(disabled("No sessions running"))
        } else {
            for state in [SessionState.awaitingAnswer, .apiError, .ready, .running] {
                let n = sessions.filter { $0.state == state }.count
                guard n > 0 else { continue }
                menu.addItem(disabled("\(n) \(state.label.lowercased())"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(muteItem())

        menu.addItem(.separator())
        menu.addItem(submenu(title: "Show By Itself After",
                             items: Settings.idleChoices.map {
                                 (Self.idleLabel($0), $0 == Settings.idleThreshold,
                                  #selector(pickIdle(_:)), $0 as Any)
                             }))
        menu.addItem(submenu(title: "Panel Shortcut",
                             items: Settings.panelChoices.map {
                                 ($0.label, $0 == Settings.panelChord,
                                  #selector(pickPanelChord(_:)), $0 as Any)
                             }))
        menu.addItem(submenu(title: "Mute Shortcut",
                             items: Settings.muteChoices.map {
                                 ($0.label, $0 == Settings.muteChord,
                                  #selector(pickMuteChord(_:)), $0 as Any)
                             }))

        // Only offered while it is missing. Installed, it has nothing to say and no reason to
        // sit in the menu — and without it the dot beside the plane is a guess, which is worth
        // one line of menu to fix.
        if !Hooks.isInstalled {
            menu.addItem(withTitle: Hooks.isOutdated ? "Update Session-State Hooks…"
                                                     : "Install Session-State Hooks…",
                         action: #selector(installHooks), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        // "until login" is not hedging: the LaunchAgent has KeepAlive set, so a plain
        // terminate would have launchd start us again a second later.
        menu.addItem(withTitle: "Quit Fleet (until next login)",
                     action: #selector(quit), keyEquivalent: "q")
            .target = self

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The mute row, which is also the only place the countdown is written down — the hollow
    /// plane says *that* Fleet is muted, not for how much longer.
    private func muteItem() -> NSMenuItem {
        let title: String
        if let left = controller.muteRemaining {
            title = "Unmute (\(max(1, Int(left / 60))) min left)"
        } else {
            title = "Mute for \(Int(Settings.muteDuration / 60)) Minutes"
        }
        let entry = NSMenuItem(title: title, action: #selector(toggleMute), keyEquivalent: "")
        entry.target = self
        return entry
    }

    /// One settings submenu: a radio list where the current value is ticked. The chosen value
    /// rides on the item's `representedObject`, so all three lists share one shape.
    private func submenu(title: String,
                         items: [(String, Bool, Selector, Any)]) -> NSMenuItem {
        let sub = NSMenu()
        for (label, current, action, value) in items {
            let entry = NSMenuItem(title: label, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = value
            entry.state = current ? .on : .off
            sub.addItem(entry)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private static func idleLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Never — only when I ask" }
        return seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minutes"
    }

    @objc private func toggleMute() {
        controller.toggleMute()
    }

    @objc private func pickIdle(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        Settings.idleThreshold = seconds
    }

    @objc private func pickPanelChord(_ sender: NSMenuItem) {
        guard let chord = sender.representedObject as? Settings.Chord else { return }
        Settings.panelChord = chord
        controller.bindHotKeys()
    }

    @objc private func pickMuteChord(_ sender: NSMenuItem) {
        guard let chord = sender.representedObject as? Settings.Chord else { return }
        Settings.muteChord = chord
        controller.bindHotKeys()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    @objc private func showPanel() {
        controller.forceShow(announceEmpty: true)
    }

    /// Asks first, because this writes to a file the user owns and Fleet did not create.
    @objc private func installHooks() {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "Let Claude Code report what each session is doing?"
        ask.informativeText = """
            Fleet currently works out a session's state by reading its transcript, which it \
            sometimes gets wrong — a session that has finished can show as busy.

            This adds hooks to ~/.claude/settings.json so Claude Code tells Fleet directly when \
            a turn ends, when it needs you, and when it is working. Your existing settings are \
            kept, and a copy is saved beside them.
            """
        ask.addButton(withTitle: "Install")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let done = NSAlert()
        do {
            let path = try Hooks.install()
            done.messageText = "Installed"
            done.informativeText = "Hooks added to \(path). Sessions already running keep the "
                + "old inferred state until they are restarted."
        } catch {
            done.alertStyle = .warning
            done.messageText = "Could not install the hooks"
            done.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        done.runModal()
    }

    /// `NSApp.terminate` alone is not enough when we were started by the LaunchAgent: KeepAlive
    /// brings us straight back. Unloading the job stops that until the next login re-loads it
    /// from the plist. When Fleet was launched by hand there is no job, and we just exit.
    @objc private func quit() {
        let job = "gui/\(getuid())/com.mr.fleet"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", job]
        try? task.run()          // kills us on success; the terminate below covers the rest
        task.waitUntilExit()
        NSApp.terminate(nil)
    }
}
