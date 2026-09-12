import AppKit
import SwiftUI

/// The window behind a right-click on the menu bar plane: everything Fleet can be told, on one
/// page. It used to be a `NSMenu` with three submenus, which is fine for four commands and
/// wrong for settings — a radio list you have to hover open to read is a poor place to see what
/// your own shortcuts currently are.
@MainActor
final class ControlCenterController {

    private var window: NSWindow?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // Same reasoning as the panel: order in before activating, so the window joins the
        // desktop you are on rather than dragging you to the one macOS last filed us under.
        window.setFrameOrigin(Self.centred(window))
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Fleet"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(ControlCenterView.background)
        window.appearance = NSAppearance(named: .darkAqua)
        // Closing must not deallocate it: the controller keeps the reference and reopens it.
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        // The hosting view sizes the window to what SwiftUI asks for, which is why the root
        // view states a width and no height: the height is whatever the sections come to, and
        // the window is exactly that tall. Pinning it instead — at 620, as it was — is what
        // made every paragraph in here end in an ellipsis.
        window.contentView = NSHostingView(rootView: ControlCenterView(controller: controller))
        return window
    }

    /// Centred on the screen the pointer is on — `NSScreen.main` names whichever screen holds
    /// the key window, which for a background agent can be one you are not looking at.
    private static func centred(_ window: NSWindow) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        return NSPoint(x: frame.midX - window.frame.width / 2,
                       y: frame.midY - window.frame.height / 2)
    }
}

struct ControlCenterView: View {
    @ObservedObject var controller: AppController

    // The settings live in `UserDefaults`, which SwiftUI does not observe: without a local copy
    // the picker would snap back to the old row until something else redrew the view.
    @State private var idle = Settings.idleThreshold
    @State private var panelChord = Settings.panelChord
    @State private var muteChord = Settings.muteChord

    static let background = Color(red: 0.055, green: 0.055, blue: 0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            mute
            section("WHEN IT APPEARS") { idlePicker }
            section("SHORTCUTS") {
                chordPicker("Open the panel", choices: Settings.panelChoices,
                            selection: Binding(get: { panelChord }, set: {
                                panelChord = $0
                                Settings.panelChord = $0
                                controller.bindHotKeys()
                            }))
                chordPicker("Mute", choices: Settings.muteChoices,
                            selection: Binding(get: { muteChord }, set: {
                                muteChord = $0
                                Settings.muteChord = $0
                                controller.bindHotKeys()
                            }))
                tileNumbers
            }
            section("SESSION STATE") {
                legend
                hooks
            }
            footer
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(width: 420, alignment: .leading)
        .background(Self.background)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FLEET")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.85))
            Text(fleetSummary)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var fleetSummary: String {
        let sessions = controller.sessions
        guard !sessions.isEmpty else { return "No Claude Code sessions running" }
        let parts = [SessionState.awaitingAnswer, .apiError, .delegated, .ready, .running]
            .compactMap {
            state -> String? in
            let n = sessions.filter { $0.state == state }.count
            return n > 0 ? "\(n) \(state.label.lowercased())" : nil
        }
        return parts.joined(separator: " · ")
    }

    /// The mute row states its own end time rather than counting down: a countdown needs a
    /// timer redrawing this window once a second for a number nobody watches.
    private var mute: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.mutedUntil == nil ? SessionState.ready.tint
                                                   : SessionState.apiError.tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.muteRemaining == nil ? "Fleet may show itself"
                                                     : "Muted until \(muteEndTime)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(muteChord.label) mutes it for "
                     + "\(Int(Settings.muteDuration / 60)) minutes. It still opens when you ask.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 8)
            wideButton(controller.muteRemaining == nil ? "Mute" : "Unmute", width: 76) {
                controller.toggleMute()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.06)))
    }

    private var muteEndTime: String {
        guard let until = controller.mutedUntil else { return "" }
        return until.formatted(date: .omitted, time: .shortened)
    }

    private var idlePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Show by itself after") {
                Picker("", selection: Binding(get: { idle },
                                              set: { idle = $0; Settings.idleThreshold = $0 })) {
                    ForEach(Settings.idleChoices, id: \.self) {
                        Text(Self.idleLabel($0)).tag($0)
                    }
                }
                .labelsHidden()
            }
            Text("How long the machine has to sit untouched before the panel opens on its own. "
                 + "It stays away while a video is playing or a microphone is recording.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func chordPicker(_ title: String, choices: [Settings.Chord],
                             selection: Binding<Settings.Chord>) -> some View {
        row(title) {
            // A list of chords rather than a recorder that captures whatever you press: the
            // recorder is a window's worth of code, and these are the combinations that are
            // actually free.
            Picker("", selection: selection) {
                ForEach(choices, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
        }
    }

    /// ⌘-digit is only worth learning if the digit holds still, and it only holds still if you
    /// say which project owns it. The list is a text file — see `Slots`.
    private var tileNumbers: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Tile numbers") {
                wideButton("Edit…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Slots.path))
                }
            }
            Text("⌘1 to ⌘9 open the tile wearing that number while the panel is up. A project "
                 + "pinned to a number takes it back whenever it is running; while it is away "
                 + "the number is free like any other.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What each border colour means. The panel is colour and almost nothing else — four
    /// states and a fifth that is easy to mistake for green — so the key belongs somewhere you
    /// can read it, and this window is the only page Fleet has.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.meanings.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.state.label)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(entry.state.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(entry.state.tint.opacity(0.15), in: Capsule())
                        .frame(width: 96, alignment: .leading)
                    Text(entry.meaning)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
    }

    /// Green, blue, purple, red, orange — his order. One line each: this column is 262 points
    /// wide and a description that wraps turns the key into a paragraph.
    private static let meanings: [(state: SessionState, meaning: String)] = [
        (.ready, "Finished its turn. Yours to type into."),
        (.awaitingAnswer, "A question or a permission is on screen."),
        (.delegated, "Sub-agents working, the session is free."),
        (.running, "A tool is in flight."),
        (.apiError, "The request failed. It is retrying."),
    ]

    @ViewBuilder private var hooks: some View {
        if Hooks.isInstalled {
            Text("Claude Code reports each session's state to Fleet directly.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fleet is guessing each session's state from its transcript, which it "
                     + "sometimes gets wrong. Hooks let Claude Code say so itself.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                Button(Hooks.isOutdated ? "Update Hooks…" : "Install Hooks…") { installHooks() }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            wideButton("Show Panel") { controller.forceShow() }
            Spacer(minLength: 4)
            // "until login" is not hedging: the LaunchAgent has KeepAlive set, so a plain
            // terminate would have launchd start us again a second later.
            wideButton("Quit until next login") { quit() }
        }
    }

    // MARK: - Layout helpers

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.35))
            content()
        }
    }

    /// Every control in the window lives in a slot this wide, against the same right edge —
    /// pickers, buttons, both footer buttons. They were each their own width before, which put
    /// four different right edges down one short column.
    static let controlWidth: CGFloat = 178

    /// A button of a stated width. The width has to go on the *label*: given it on the button
    /// itself, the chrome keeps hugging its title and only the invisible frame around it grows,
    /// which is how four buttons in one window ended up four different sizes.
    private func wideButton(_ title: String, width: CGFloat = ControlCenterView.controlWidth,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .frame(width: width)
    }

    private func row<Control: View>(_ title: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 12)
            // Trailing: a popup button draws at the width of its own longest title and
            // centres itself in whatever frame it is given, so a common width is not
            // something a Picker will honour. A common right edge it will.
            control().frame(width: Self.controlWidth, alignment: .trailing)
        }
    }

    private static func idleLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Never — only when I ask" }
        return seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minutes"
    }

    /// Asks first, because this writes to a file the user owns and Fleet did not create.
    private func installHooks() {
        let ask = NSAlert()
        ask.messageText = "Let Claude Code report what each session is doing?"
        ask.informativeText = """
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

    private func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/com.mr.fleet"]
        try? task.run()          // kills us on success; the terminate below covers the rest
        task.waitUntilExit()
        NSApp.terminate(nil)
    }
}
