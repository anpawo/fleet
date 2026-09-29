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
        let hosting = NSHostingView(rootView: ControlCenterView(controller: controller))
        window.contentView = hosting
        // Stated rather than left to the constraints the hosting view installs: landing a few
        // points under what the content asked for does not scroll or clip, it *compresses* —
        // every wrapping paragraph loses its second line and ends in an ellipsis instead.
        window.setContentSize(hosting.fittingSize)
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

    static let background = Color(red: 0.055, green: 0.055, blue: 0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            status
            section("WHEN IT APPEARS") {
                idlePicker
                row("Jarvis") {
                    menu([true, false], label: { $0 ? "On" : "Off" },
                         selection: $controller.jarvisOn)
                }
            }
            section("SHORTCUTS") {
                chordPicker("Open the panel", choices: Settings.panelChoices,
                            selection: Binding(get: { panelChord }, set: {
                                panelChord = $0
                                Settings.panelChord = $0
                                controller.bindHotKeys()
                            }))
            }
            hooks
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
        let parts = [SessionState.awaitingAnswer, .apiError, .delegated, .paused, .ready, .running]
            .compactMap {
            state -> String? in
            let n = sessions.filter { $0.state == state }.count
            return n > 0 ? "\(n) \(state.label.lowercased())" : nil
        }
        return parts.joined(separator: " · ")
    }

    private var status: some View {
        let off = controller.popupsOff
        return HStack(spacing: 12) {
            Circle()
                .fill(off ? SessionState.running.tint : SessionState.ready.tint)
                .frame(width: 8, height: 8)
            Text(off ? "Fleet never shows itself" : "Fleet may show itself")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            wideButton(off ? "Turn on" : "Turn off", width: 76) {
                controller.popupsOff.toggle()
                if controller.popupsOff, controller.isPanelVisible { controller.hidePanel() }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.06)))
    }

    private var idlePicker: some View {
        row("Show by itself after") {
            menu(Settings.idleChoices, label: Self.idleLabel,
                 selection: Binding(get: { idle },
                                    set: { idle = $0; Settings.idleThreshold = $0 }))
        }
    }

    private func chordPicker(_ title: String, choices: [Settings.Chord],
                             selection: Binding<Settings.Chord>) -> some View {
        row(title) {
            // A list of chords rather than a recorder that captures whatever you press: the
            // recorder is a window's worth of code, and these are the combinations that are
            // actually free.
            menu(choices, label: \.label, selection: selection)
        }
    }

    @ViewBuilder private var hooks: some View {
        if !Hooks.isInstalled {
            wideButton(Hooks.isOutdated ? "Update Hooks…" : "Install Hooks…") { installHooks() }
        }
    }

    private var footer: some View {
        // No spacing of its own: two control widths and two gaps came to 12pt more than the
        // column, and the right button stood past the edge the popups end on.
        HStack(spacing: 0) {
            wideButton("Show Panel") { controller.forceShow() }
            Spacer(minLength: 0)
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

    /// And this tall: the line of the label beside it. The system push button and the popups
    /// each stood taller than their row, at two different heights (asked 2026-09-28).
    static let controlHeight: CGFloat = 20

    /// The ground every control wears, popups and buttons alike.
    fileprivate static func controlGround(pressed: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.white.opacity(pressed ? 0.18 : 0.10))
    }

    /// A popup that is the width you tell it.
    ///
    /// `Picker` is not: it measures its longest title, draws that wide, and centres itself in
    /// whatever frame it is handed — which is why the two chord popups came out narrower than
    /// the idle one and narrower than each other. A `Menu` with a label of our own is the same
    /// control with the width under our control, and it takes the same chrome as the buttons
    /// beside it.
    private func menu<T: Hashable>(_ options: [T], label: @escaping (T) -> String,
                                   selection: Binding<T>) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(selection.wrappedValue))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: Self.controlHeight)
            .background(Self.controlGround())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: ControlCenterView.controlWidth)
    }

    /// A button of a stated width. The width has to go on the *label*: given it on the button
    /// itself, the chrome keeps hugging its title and only the invisible frame around it grows,
    /// which is how four buttons in one window ended up four different sizes.
    private func wideButton(_ title: String, width: CGFloat = ControlCenterView.controlWidth,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(LineButton())
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

    /// A push button in the popups' chrome and at their height.
    private struct LineButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(height: ControlCenterView.controlHeight)
                .background(ControlCenterView.controlGround(pressed: configuration.isPressed))
                .contentShape(Rectangle())
        }
    }

    private func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/app.fleet"]
        try? task.run()          // kills us on success; the terminate below covers the rest
        task.waitUntilExit()
        NSApp.terminate(nil)
    }
}
