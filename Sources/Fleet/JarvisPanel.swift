import AppKit
import SwiftUI

/// What the panel shows. Every size is worked out here rather than left to SwiftUI, so the
/// window can be framed before the view has drawn once.
@MainActor
final class JarvisModel: ObservableObject {
    @Published var project = ""
    @Published var line = ""
    @Published var task: String?
    /// The switch-on briefing: nothing to take, nothing to type.
    @Published var briefing = false
    @Published var queued = 0
    @Published var live = true
    @Published var typing = false
    @Published var failure: String?
    @Published var draft = ""
    @Published var shown = false
    var screenWidth: CGFloat = 1470
    let orb = OrbModel()
    var act: (JarvisPanel.Action) -> Void = { _ in }

    /// Every key is a black square this tall; the task's is as wide as its text, up to `taskMax`.
    static let square: CGFloat = 53, squareGap: CGFloat = 8, inset: CGFloat = 12
    static let taskMax: CGFloat = 420, hintWidth: CGFloat = 24
    /// The black tray the keys sit in, this far from its edge; ✕ on its left and Other on
    /// its right stand `apart` from the task.
    static let tray: CGFloat = 8, apart: CGFloat = 32, otherWidth: CGFloat = 84
    /// Clear space over the orb, and between it and the squares.
    static let top: CGFloat = 12, gap: CGFloat = 12, orb: CGFloat = 36
    static let labelFont = NSFont.systemFont(ofSize: 15)
    static let failureFont = NSFont.systemFont(ofSize: 12)
    static let other = "Something else…"
    /// The tray is Fleet's sessions panel wash (OverlayView.tintOpacity); the keys on it are opaque,
    /// like Fleet's tiles. The text is always drawn for dark.
    static let fill = Color.black.opacity(0.8)
    /// Only a failure takes a text block, on two lines: the line itself is spoken, not shown.
    static let headerWidth: CGFloat = 240

    static func taskWidth(_ task: String) -> CGFloat {
        let text = ceil((task as NSString).size(withAttributes: [.font: labelFont]).width)
        return min(text + 2 * inset + squareGap + hintWidth, taskMax)
    }
    var itemsWidth: CGFloat {
        let task = self.task.map(Self.taskWidth) ?? 0
        let other = briefing ? 0 : Self.otherWidth
        return task + other + (task > 0 && other > 0 ? Self.apart : 0)
    }
    var fieldWidth: CGFloat { max(itemsWidth, 360) }
    var rest: CGFloat {
        (failure != nil ? Self.headerWidth + 2 * Self.inset + Self.squareGap : 0) + (typing ? fieldWidth : itemsWidth)
    }
    var width: CGFloat { 2 * Self.tray + Self.square + (rest > 0 ? Self.apart + rest : 0) }
    var height: CGFloat { Self.top + Self.orb + Self.gap + Self.square + 2 * Self.tray }

    static func check(_ expect: (CGFloat, CGFloat, String) -> Void) {
        let m = JarvisModel()
        m.task = "Run the tests"
        expect(m.width, 2 * tray + square + apart + taskWidth("Run the tests") + apart + otherWidth,
               "jarvis: ✕, the task and Other fill their tray")
        m.task = String(repeating: "long words ", count: 60)
        expect(taskWidth(m.task!), taskMax, "jarvis: a long task wraps at the cap")
        m.task = nil
        m.briefing = true
        expect(m.width, 2 * tray + square, "jarvis: the briefing shows ✕ alone")
    }
}

/// The orb's inputs, set by `Jarvis`, and the shader parameters gliding toward them. Not
/// published: the orb's own Metal view reads it every frame, and nothing else draws from it.
@MainActor
final class OrbModel {
    enum Mode { case preparing, waiting, silent }
    private var mode = Mode.waiting
    private var level = 0.0
    private var speaking = false
    /// A fixed clock for the offscreen renders, with the parameters at rest on their targets.
    var frozen: Double?
    private var phase: Float = 1.7
    private var last: Double?
    private var params = OrbShader.Params.idle

    func set(_ mode: Mode) {
        self.mode = mode
        speaking = false
        level = 0
    }

    /// The smoothed RMS the voice reports, 0…1, while it plays.
    func frame(level: Double, speaking: Bool) {
        self.level = level
        self.speaking = speaking
    }

    func uniforms(at date: Date, pixels: Float) -> [Float] {
        let target: OrbShader.Params = mode == .silent ? .disabled : speaking ? .speaking : mode == .preparing ? .connecting : .idle
        let level = Float(speaking ? self.level : 0)
        if let frozen { return OrbShader.uniforms(target, level: level, phase: Float(frozen), pixels: pixels) }
        let now = date.timeIntervalSinceReferenceDate
        // Capped: after a pause the first frame would otherwise jump.
        let dt = Float(min(max(now - (last ?? now), 0), 1.0 / 30))
        last = now
        params = params.approach(target, 1 - exp(-dt / 0.2))
        phase += dt * params.speed * (1 + 0.7 * params.voice * level)
        return OrbShader.uniforms(params, level: level, phase: phase, pixels: pixels)
    }
}

/// Never key, except while Marius types after 0: a non-activating panel takes the keyboard
/// without activating Fleet, so the app he was in stays the active one.
final class JarvisWindow: NSPanel {
    var typing = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Session text never shows in a screen share or a recording.
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { typing }
    override var canBecomeMain: Bool { false }
}

private final class JarvisHost: NSHostingView<JarvisView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The orb under the notch and the task bar under it, in one window.
@MainActor
final class JarvisPanel {
    enum Action { case take, type, submit(String), close, rearm }

    let model = JarvisModel()
    private lazy var window: JarvisWindow = {
        let w = JarvisWindow()
        w.contentView = JarvisHost(rootView: JarvisView(model: model))
        w.appearance = NSAppearance(named: .darkAqua)
        return w
    }()
    private var hiding: DispatchWorkItem?
    private var top: CGFloat = 0
    private var midX: CGFloat = 0

    func show() {
        hiding?.cancel()
        hiding = nil
        let screen = OverlayWindowController.activeScreen()
        let notch = Self.notch(of: screen)
        top = notch.top
        midX = notch.midX
        model.screenWidth = screen.frame.width
        relayout()
        window.orderFrontRegardless()
        // One turn later, so the view has drawn folded and the springs have somewhere to start.
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    func relayout() {
        window.setFrame(CGRect(x: (midX - model.width / 2).rounded(), y: top - model.height,
                               width: model.width, height: model.height), display: true)
        window.invalidateShadow()
    }

    func hide() {
        model.shown = false
        endTyping()
        let work = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func beginTyping() {
        window.typing = true
        relayout()
        window.makeKey()
    }

    /// Ordering out is what hands the keyboard back: the panel never activated Fleet, so the
    /// app underneath is still the active one and takes its key window back.
    func endTyping() {
        guard window.typing else { return }
        window.typing = false
        if window.isKeyWindow {
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
        relayout()
    }

    /// Where the window hangs from: the notch's bottom edge, centred on it; on a screen without
    /// one, the menu bar's bottom edge. The width only draws the notch in the renders.
    static func notch(of screen: NSScreen) -> (width: CGFloat, notched: Bool, top: CGFloat, midX: CGFloat) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return (width, true, screen.frame.maxY - screen.safeAreaInsets.top,
                    screen.frame.minX + left.width + width / 2)
        }
        return (0, false, screen.visibleFrame.maxY, screen.frame.midX)
    }

    // MARK: - Render

    /// `--render-jarvis <dir>`: every state as a PNG, drawn offscreen under a drawn notch.
    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let real = NSScreen.screens.lazy.map { notch(of: $0) }.first { $0.notched }
        let notchWidth = real?.width ?? 185
        let task = "Commit and push the rework"
        func speaking(_ level: Double) -> (JarvisModel) -> Void {
            { $0.task = task; $0.orb.set(.preparing); $0.orb.frame(level: level, speaking: true) }
        }
        typealias Scene = (name: String, dark: Bool, notched: Bool, clock: Double, setup: (JarvisModel) -> Void)
        let scenes: [Scene] = [
            ("1-live-dark", true, true, 2, speaking(0.5)),
            ("3-live-light", false, true, 2, { speaking(0.6)($0); $0.queued = 2 }),
            ("short-dark", true, true, 2, { $0.task = "Run the tests"; $0.live = false }),
            ("long-dark", true, true, 2, { $0.task = String(repeating: "Check the render of the crons column ", count: 4); $0.live = false }),
            ("notask-dark", true, true, 2, { $0.live = false }),
            ("briefing-dark", true, true, 2, { $0.briefing = true; $0.orb.set(.preparing); $0.orb.frame(level: 0.5, speaking: true) }),
            ("typing-dark", true, true, 2, { $0.task = task; $0.typing = true; $0.draft = "also bump the version" }),
            ("novoice-dark", true, true, 2, { $0.task = task; $0.orb.set(.silent) }),
            ("error-light", false, true, 2, { $0.task = task; $0.orb.set(.silent)
                $0.failure = "Didn't reach portfolio: the session moved on. Your answer is on the clipboard." }),
            ("nonotch-dark", true, false, 2, speaking(0.4)),
            ("orb-phase-a", true, true, 0, speaking(0.3)),
            ("orb-loud", true, true, 1.4, speaking(1)),
        ]
        for scene in scenes {
            let m = JarvisModel()
            m.project = "portfolio"
            m.line = "Portfolio is done, sir."
            m.shown = true
            m.orb.frozen = scene.clock
            scene.setup(m)
            let bar: CGFloat = scene.notched ? 32 : 28
            let size = CGSize(width: m.width + 120, height: bar + m.height + 30)
            let view = VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(scene.dark ? Color(white: 0.16) : Color(white: 0.93))
                    if scene.notched {
                        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).fill(.black)
                            .frame(width: notchWidth)
                    }
                }
                .frame(height: bar)
                JarvisView(model: m)
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height)
            .background(scene.dark ? Color(red: 0.12, green: 0.14, blue: 0.2) : Color(red: 0.72, green: 0.78, blue: 0.86))
            // The orb frames are cropped to the orb and blown up, so the swirl can be told apart.
            let orbOnly = scene.name.hasPrefix("orb-")
            let host = NSHostingView(rootView: AnyView(orbOnly
                ? AnyView(view.frame(width: 120, height: 120, alignment: .top).offset(y: -bar - JarvisModel.top + 42)
                    .frame(width: 120, height: 120).clipped().scaleEffect(4).frame(width: 480, height: 480))
                : AnyView(view)))
            host.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: orbOnly ? CGSize(width: 480, height: 480) : size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = (dir as NSString).appendingPathComponent("jarvis-\(scene.name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        print("notch width \(notchWidth) pt\(real == nil ? " (no notched screen found, assumed)" : "")")
    }
}

// MARK: - Views

struct JarvisView: View {
    @ObservedObject var model: JarvisModel

    private static let enter = Animation.spring(response: 0.30, dampingFraction: 0.85)
    private static let leave = Animation.spring(response: 0.22, dampingFraction: 1)

    var body: some View {
        VStack(spacing: JarvisModel.gap) {
            OrbView(orb: model.orb, running: model.shown)
                .overlay(alignment: .leading) {
                    if model.queued > 0 {
                        QueueBadge(count: model.queued).fixedSize().offset(x: JarvisModel.orb + 8)
                    }
                }
                .scaleEffect(model.shown ? 1 : 0.5)
                .opacity(model.shown ? 1 : 0)
                .animation(model.shown ? Self.enter : Self.leave, value: model.shown)
            bar
                .opacity(model.shown ? 1 : 0)
                .offset(y: model.shown ? 0 : -8)
                .animation(model.shown ? Self.enter.delay(0.06) : Self.leave, value: model.shown)
        }
        .padding(.top, JarvisModel.top)
        .frame(width: model.width, height: model.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: JarvisModel.squareGap) {
            Square(width: JarvisModel.square, help: "Close (esc)", action: { model.act(.close) }) {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
            }
            if model.rest > 0 { Dash() }
            if let failure = model.failure {
                Text(failure)
                    .font(Font(JarvisModel.failureFont))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: JarvisModel.headerWidth, alignment: .leading)
                    .padding(.horizontal, JarvisModel.inset)
                    .frame(height: JarvisModel.square)
            }
            if model.typing {
                TypingField(model: model)
            } else {
                if let task = model.task {
                    Square(width: JarvisModel.taskWidth(task), help: "\(task) (tab)", action: { model.act(.take) }) {
                        HStack(spacing: JarvisModel.squareGap) {
                            Text(task)
                                .font(Font(JarvisModel.labelFont))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("tab")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: JarvisModel.hintWidth)
                        }
                        .padding(.horizontal, JarvisModel.inset)
                    }
                    if !model.briefing { Dash() }
                }
                if !model.briefing {
                    Square(width: JarvisModel.otherWidth, help: "\(JarvisModel.other) (0)",
                           action: { model.act(.type) }) {
                        Text("Other").font(.system(size: 17, weight: .semibold))
                    }
                }
            }
        }
        .padding(JarvisModel.tray)
        .frame(width: model.width, height: JarvisModel.square + 2 * JarvisModel.tray, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12 + JarvisModel.tray).fill(JarvisModel.fill))
        .contentShape(Rectangle())
        // A click between the keys says his attention is here: the keys come back.
        .onTapGesture { model.act(.rearm) }
    }
}

/// The short dash that sets ✕ and Other apart from the task.
private struct Dash: View {
    var body: some View {
        Capsule().fill(.white.opacity(0.35)).frame(width: 8, height: 2)
            .frame(width: JarvisModel.apart - 2 * JarvisModel.squareGap)
    }
}

/// One outlined key in the tray: the task, Other or ✕.
private struct Square<Label: View>: View {
    let width: CGFloat
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false

    var body: some View {
        label
            .foregroundStyle(.white)
            .frame(width: width, height: JarvisModel.square)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Color(white: 0.12) : .black))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
            .help(help)
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

/// After 0 the field takes the keys' place, so the answer is typed where the task was.
private struct TypingField: View {
    @ObservedObject var model: JarvisModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: JarvisModel.inset) {
            TextField("Tell \(model.project) what to do", text: $model.draft)
                .textFieldStyle(.plain)
                .font(Font(JarvisModel.labelFont))
                .focused($focused)
                .onSubmit { model.act(.submit(model.draft)) }
                .onAppear { focused = true }
        }
        .padding(.horizontal, JarvisModel.inset)
        .frame(width: model.fieldWidth, height: JarvisModel.square)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }
}

private struct QueueBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(JarvisModel.fill)
            .clipShape(Capsule())
    }
}

/// The shader's canvas: the ball is 80% of it at rest and swells to 88% with the voice, the
/// rest is for its halo. Every frame is drawn on the GPU and read back as an image: the same
/// path as the offscreen renders, so what they show is what the panel shows.
private struct OrbView: View {
    let orb: OrbModel
    let running: Bool
    static let canvas: CGFloat = 48
    /// Twice the Retina resolution, scaled down: the ball's rim is a hard edge.
    private static let pixels = 192

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
            let date = orb.frozen.map { Date(timeIntervalSinceReferenceDate: $0) } ?? timeline.date
            if let image = OrbShader.image(orb.uniforms(at: date, pixels: Float(Self.pixels)), pixels: Self.pixels) {
                Image(decorative: image, scale: CGFloat(Self.pixels) / Self.canvas).interpolation(.high).antialiased(true)
            }
        }
        .frame(width: Self.canvas, height: Self.canvas)
        .padding(-(Self.canvas - JarvisModel.orb) / 2)
    }
}
