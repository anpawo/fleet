import AppKit
import SwiftUI

/// What the panel shows. Every size is worked out here rather than left to SwiftUI, so the
/// window can be framed before the view has drawn once.
@MainActor
final class JarvisModel: ObservableObject {
    @Published var project = ""
    @Published var line = ""
    @Published var options: [JarvisOption] = []
    @Published var queued = 0
    @Published var live = true
    @Published var typing = false
    @Published var failure: String?
    @Published var draft = ""
    @Published var shown = false
    var screenWidth: CGFloat = 1470
    let orb = OrbModel()
    var act: (JarvisPanel.Action) -> Void = { _ in }

    // The screenshot app's ⌘⇧5 bar (my-lab/app/screenshot, Bar.swift), measured there: 53 pt
    // tall, the ✕ 17 pt at 14.5, the first item at 43.75, 36 pt items on a 6 pt gap with their
    // content 7.5 in, a 22 pt divider 10 pt after a group and 11.5 before the next, 8.5 pt after
    // the last item, 12 pt corners, 8 pt on an item, 15 pt text, 12 pt for the small print.
    static let barHeight: CGFloat = 53, closeX: CGFloat = 14.5, close: CGFloat = 17, firstX: CGFloat = 43.75
    static let item: CGFloat = 36, itemGap: CGFloat = 6, inset: CGFloat = 7.5, badge: CGFloat = 17
    static let divBefore: CGFloat = 10, divAfter: CGFloat = 11.5, trail: CGFloat = 8.5
    /// Clear space over the orb, and between it and the bar: the bar's own 24 pt off the screen
    /// edge and the 12 pt its hints float above it.
    static let top: CGFloat = 24, gap: CGFloat = 12, orb: CGFloat = 36
    static let labelFont = NSFont.systemFont(ofSize: 15)
    static let keywordFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let projectFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let failureFont = NSFont.systemFont(ofSize: 12)
    static let other = "Something else…"
    private static let chrome = inset + badge + itemGap + inset

    private static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        // A point over AppKit's measure: SwiftUI lays the same string out a hair wider.
        ceil((s as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    /// The widest a text may be so all of `widths` fit in `room`: the short ones keep their
    /// width, the long ones share what is left.
    static func cap(_ widths: [CGFloat], within room: CGFloat) -> CGFloat {
        var room = room, left = CGFloat(widths.count)
        for w in widths.sorted() {
            if w * left > room { return floor(room / left) }
            room -= w
            left -= 1
        }
        return .infinity
    }

    /// The failure takes two lines of the whole width; the project and the line one each.
    var headerWidth: CGFloat {
        if failure != nil { return 240 }
        return min(max(Self.measure(project, Self.projectFont), Self.measure(line, Self.labelFont)), 240)
    }
    private var chromeWidth: CGFloat {
        Self.firstX + headerWidth + Self.divBefore + 1 + Self.divAfter + Self.trail
    }
    private func text(_ o: JarvisOption) -> CGFloat {
        max(Self.measure(o.label, Self.labelFont), Self.measure(o.keyword, Self.keywordFont))
    }
    /// Each item as wide as its text, until the bar would come within 24 pt of the screen's
    /// sides: then the longest labels truncate, never the bar.
    var itemWidths: [CGFloat] {
        let zero = Self.measure(Self.other, Self.labelFont) + Self.chrome
        let room = screenWidth - 2 * Self.top - chromeWidth - zero
            - CGFloat(options.count) * (Self.chrome + Self.itemGap)
        let cap = min(Self.cap(options.map(text), within: room), 280)
        return options.map { min(text($0), cap) + Self.chrome } + [zero]
    }
    var itemsWidth: CGFloat { itemWidths.reduce(-Self.itemGap) { $0 + $1 + Self.itemGap } }
    var fieldWidth: CGFloat { max(itemsWidth, 360) }
    var width: CGFloat { chromeWidth + (typing ? fieldWidth : itemsWidth) }
    var height: CGFloat { Self.top + Self.orb + Self.gap + Self.barHeight }

    static func check(_ expect: (CGFloat, CGFloat, String) -> Void) {
        expect(cap([100, 200, 300], within: 450), 175, "jarvis: long labels share what the short ones leave")
        expect(cap([100, 200], within: 450), .infinity, "jarvis: labels that fit are not cut")
        let m = JarvisModel()
        m.line = "Portfolio is done, sir."
        m.options = Array(repeating: JarvisOption(label: String(repeating: "Re-render the thumbnails ", count: 4),
                                                  keyword: "sips -Z 800"), count: JarvisOptions.limit)
        expect(min(m.width, 1470 - 2 * top), m.width, "jarvis: six long options and 0 fit a 1470 pt screen")
    }
}

/// The orb's inputs, set by `Jarvis`, and the springs that carry the drawing toward them. Not
/// published: the orb's own timeline reads it every frame, and nothing else draws from it.
@MainActor
final class OrbModel {
    enum Mode { case preparing, waiting, silent }
    struct Pose { var t: Double, phase: Double, energy: Double, colour: Double }
    private var mode = Mode.waiting
    private var level = 0.0
    private var speaking = false
    /// A fixed clock for the offscreen renders, with the springs at rest on their targets.
    var frozen: Double?
    private var phase = 0.0
    private var last: Double?
    private var energy = Spring(0.12), colour = Spring(1)

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

    func pose(at date: Date) -> Pose {
        let e = mode == .silent ? 0.05 : speaking ? 0.3 + 0.7 * level : mode == .preparing ? 0.3 : 0.12
        let c = mode == .silent ? 0.0 : 1.0
        func speed(_ e: Double) -> Double { 0.35 + 1.8 * e }
        if let frozen { return Pose(t: frozen, phase: frozen * speed(e), energy: e, colour: c) }
        let now = date.timeIntervalSinceReferenceDate
        // Capped: after a pause the first frame would otherwise jump, and the stiff spring blow up.
        let dt = min(max(now - (last ?? now), 0), 1.0 / 30)
        last = now
        energy.step(to: e, response: 0.15, dt: dt)
        colour.step(to: c, response: 0.5, dt: dt)
        phase += dt * speed(energy.value)
        return Pose(t: now, phase: phase, energy: energy.value, colour: min(max(colour.value, 0), 1))
    }

    /// Integrated from where it is, so a new target mid-flight bends the motion instead of restarting it.
    private struct Spring {
        var value: Double, velocity = 0.0
        init(_ value: Double) { self.value = value }
        mutating func step(to target: Double, response: Double, dt: Double) {
            let k = pow(2 * .pi / response, 2)
            velocity += (k * (target - value) - 2 * sqrt(k) * 0.85 * velocity) * dt
            value += velocity * dt
        }
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

/// The orb under the notch and the options bar under it, in one window.
@MainActor
final class JarvisPanel {
    enum Action { case pick(Int), type, submit(String), close, rearm }

    let model = JarvisModel()
    private lazy var window: JarvisWindow = {
        let w = JarvisWindow()
        w.contentView = JarvisHost(rootView: JarvisView(model: model))
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
    /// A material cannot be captured offscreen — it samples what is behind the window — so
    /// these draw the bar on the window background colour it stands in for.
    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let real = NSScreen.screens.lazy.map { notch(of: $0) }.first { $0.notched }
        let notchWidth = real?.width ?? 185
        let a = JarvisOption(label: "Re-render the thumbnails at 2x with sips -Z 800 (my pick)", keyword: "sips -Z 800")
        let b = JarvisOption(label: "Crop them in public/thumbs/", keyword: "public/thumbs/")
        let open = JarvisOption(label: "Open portfolio", keyword: "~/self/portfolio", opens: true)
        let more = [JarvisOption(label: "Revert Hooks.swift", keyword: "Hooks.swift"),
                    JarvisOption(label: "Relance ./recon.sh --date 2026-09-27 pour vérifier.", keyword: "./recon.sh --date 2026-09-27"),
                    JarvisOption(label: "Wait for the other session", keyword: "portfolio")]
        func speaking(_ level: Double) -> (JarvisModel) -> Void {
            { $0.options = [a, b, open]; $0.orb.set(.preparing); $0.orb.frame(level: level, speaking: true) }
        }
        typealias Scene = (name: String, dark: Bool, notched: Bool, clock: Double, setup: (JarvisModel) -> Void)
        let scenes: [Scene] = [
            ("1-live-dark", true, true, 2, speaking(0.5)),
            ("3-live-dark", true, true, 2, { speaking(0.6)($0); $0.queued = 2 }),
            ("3-live-light", false, true, 2, { speaking(0.6)($0); $0.queued = 2 }),
            ("6-passive-dark", true, true, 2, { $0.options = [a, b] + more + [open]; $0.live = false }),
            ("6-passive-light", false, true, 2, { $0.options = [a, b] + more + [open]; $0.live = false }),
            ("typing-dark", true, true, 2, { $0.options = [a, b, open]; $0.typing = true; $0.draft = "also bump the version" }),
            ("typing-light", false, true, 2, { $0.options = [a, b, open]; $0.typing = true; $0.draft = "also bump the version" }),
            ("novoice-dark", true, true, 2, { $0.options = [a, open]; $0.orb.set(.silent) }),
            ("error-light", false, true, 2, { $0.options = [a, open]; $0.orb.set(.silent)
                $0.failure = "Didn't reach portfolio: the session moved on. Your answer is on the clipboard." }),
            ("nonotch-dark", true, false, 2, speaking(0.4)),
            ("orb-phase-a", true, true, 0, speaking(0.3)),
            ("orb-phase-b", true, true, 1.4, speaking(0.3)),
            ("orb-phase-c", true, true, 2.9, speaking(0.3)),
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
                JarvisView(model: m, solid: true)
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
    var solid = false

    private static let enter = Animation.spring(response: 0.30, dampingFraction: 0.85)
    private static let leave = Animation.spring(response: 0.22, dampingFraction: 1)

    var body: some View {
        VStack(spacing: JarvisModel.gap) {
            OrbView(orb: model.orb, running: model.shown)
                .overlay(alignment: .leading) {
                    if model.queued > 0 {
                        QueueBadge(count: model.queued, solid: solid).fixedSize().offset(x: JarvisModel.orb + 8)
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
    }

    private var bar: some View {
        let ink = Color(nsColor: .labelColor)
        let widths = model.itemWidths
        return HStack(spacing: 0) {
            Button { model.act(.close) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(0.4))
                    .frame(width: JarvisModel.close, height: JarvisModel.close)
            }
            .buttonStyle(.plain)
            .padding(.leading, JarvisModel.closeX)
            header
                .frame(width: model.headerWidth, alignment: .leading)
                .padding(.leading, JarvisModel.firstX - JarvisModel.closeX - JarvisModel.close)
            Rectangle().fill(ink.opacity(0.18)).frame(width: 1, height: 22)
                .padding(.leading, JarvisModel.divBefore)
                .padding(.trailing, JarvisModel.divAfter)
            if model.typing {
                TypingField(model: model)
            } else {
                HStack(spacing: JarvisModel.itemGap) {
                    ForEach(Array(model.options.enumerated()), id: \.offset) { i, option in
                        OptionItem(model: model, digit: i + 1, option: option).frame(width: widths[i])
                    }
                    OptionItem(model: model, digit: 0, option: nil).frame(width: widths[widths.count - 1])
                }
                .opacity(model.failure != nil ? 0.35 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, JarvisModel.trail)
        .frame(width: model.width, height: JarvisModel.barHeight)
        .background {
            if solid { Color(nsColor: .windowBackgroundColor) } else { EffectBackground(radius: 12) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        // A click anywhere on the bar says his attention is here: the digits come back.
        .onTapGesture { model.act(.rearm) }
    }

    private var header: some View {
        let ink = Color(nsColor: .labelColor)
        return VStack(alignment: .leading, spacing: 0) {
            if let failure = model.failure {
                Text(failure)
                    .font(Font(JarvisModel.failureFont))
                    .foregroundStyle(ink)
                    .lineLimit(2)
            } else {
                Text(model.project)
                    .font(Font(JarvisModel.projectFont))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
                Text(model.line)
                    .font(Font(JarvisModel.labelFont))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
        }
        .truncationMode(.tail)
    }
}

/// The digit that answers, on a 17 pt disc like the bar's ✕.
private struct Badge: View {
    let digit: Int
    let ink: Color
    let lit: Bool

    var body: some View {
        Text("\(digit)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(ink)
            .frame(width: JarvisModel.badge, height: JarvisModel.badge)
            .background(Circle().fill(ink.opacity(0.15)))
            .opacity(lit ? 1 : 0.35)
    }
}

/// One option: the digit, the label, what it touches under it. 1 sits on the accent like the
/// bar's Capture button; the others on the bar's hover tint.
private struct OptionItem: View {
    @ObservedObject var model: JarvisModel
    let digit: Int
    let option: JarvisOption?
    @State private var hover = false

    var body: some View {
        let label = Color(nsColor: .labelColor)
        let primary = digit == 1
        let ink = primary ? Color.white : label
        HStack(spacing: JarvisModel.itemGap) {
            Badge(digit: digit, ink: ink, lit: model.live)
            if let option {
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(Font(JarvisModel.labelFont))
                        .foregroundStyle(ink)
                    Text(option.keyword)
                        .font(Font(JarvisModel.keywordFont))
                        .foregroundStyle(ink.opacity(primary ? 0.75 : 0.5))
                }
                .lineLimit(1)
                .truncationMode(.tail)
            } else {
                Text(JarvisModel.other)
                    .font(Font(JarvisModel.labelFont))
                    .foregroundStyle(label.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, JarvisModel.inset)
        .frame(height: JarvisModel.item)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            primary ? Color(nsColor: .controlAccentColor) : hover ? label.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .help(option.map { "\($0.label)\n\($0.keyword)" } ?? JarvisModel.other)
        .onHover { hover = $0 }
        .onTapGesture { model.act(digit == 0 ? .type : .pick(digit)) }
    }
}

/// After 0 the field takes the items' place in the bar, so the answer is typed where the
/// options were; the bar only widens when they were too few to leave it room.
private struct TypingField: View {
    @ObservedObject var model: JarvisModel
    @FocusState private var focused: Bool

    var body: some View {
        let label = Color(nsColor: .labelColor)
        HStack(spacing: JarvisModel.itemGap) {
            Badge(digit: 0, ink: label, lit: true)
            TextField("Tell \(model.project) what to do", text: $model.draft)
                .textFieldStyle(.plain)
                .font(Font(JarvisModel.labelFont))
                .focused($focused)
                .onSubmit { model.act(.submit(model.draft)) }
                .onAppear { focused = true }
            Text("⏎ send   esc back")
                .font(.system(size: 12))
                .foregroundStyle(label.opacity(0.4))
                .fixedSize()
        }
        .padding(.horizontal, JarvisModel.inset)
        .frame(width: model.fieldWidth, height: JarvisModel.item)
        .background(RoundedRectangle(cornerRadius: 8).fill(label.opacity(0.1)))
    }
}

private struct QueueBadge: View {
    let count: Int
    let solid: Bool

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background {
                if solid { Color(nsColor: .windowBackgroundColor) } else { EffectBackground(radius: 11) }
            }
            .clipShape(Capsule())
    }
}

/// Siri's orb, redrawn: soft colour blobs that swirl and morph inside a dark sphere, a halo
/// that breathes, and both swell with the voice. Radial gradients rather than blurred shapes:
/// a blur is a filter, filters are the first thing an offscreen render drops, and a dozen
/// gradient fills on a 60 pt canvas cost next to nothing at 60 fps.
private struct OrbView: View {
    let orb: OrbModel
    let running: Bool
    private static let halo: CGFloat = 12
    private static let blobs: [(rgb: (Double, Double, Double), speed: Double, offset: Double)] = [
        ((1, 0.18, 0.62), 1, 0), ((0.62, 0.25, 1), -0.8, 1.6), ((0.12, 0.38, 1), 0.65, 3.2), ((0.15, 0.85, 1), -1.15, 4.7),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
            let pose = orb.pose(at: timeline.date)
            Canvas { ctx, size in Self.draw(pose, in: &ctx, size: size) }
        }
        .frame(width: JarvisModel.orb + 2 * Self.halo, height: JarvisModel.orb + 2 * Self.halo)
        .padding(-Self.halo)
    }

    private static func draw(_ p: OrbModel.Pose, in ctx: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let e = p.energy
        let breath = 0.5 + 0.5 * sin(p.t * 2 * .pi / 4)
        let r = JarvisModel.orb / 2 * (0.9 + 0.04 * breath + 0.1 * e)
        // Toward each colour's own luminance as the colour spring falls: "no voice" is the same orb, grey.
        func tint(_ rgb: (Double, Double, Double), _ alpha: Double) -> Color {
            let l = 0.3 * rgb.0 + 0.59 * rgb.1 + 0.11 * rgb.2
            func mix(_ x: Double) -> Double { l + (x - l) * p.colour }
            return Color(red: mix(rgb.0), green: mix(rgb.1), blue: mix(rgb.2), opacity: alpha)
        }
        func disc(_ o: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: o.x - radius, y: o.y - radius, width: 2 * radius, height: 2 * radius))
        }
        func glow(_ color: Color, at o: CGPoint, from inner: CGFloat = 0, to outer: CGFloat) -> GraphicsContext.Shading {
            .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: o, startRadius: inner, endRadius: outer)
        }

        let halo = tint((0.62, 0.3, 1), (0.2 + 0.4 * e) * (0.6 + 0.4 * breath))
        ctx.fill(disc(c, r + Self.halo), with: glow(halo, at: c, from: r * 0.7, to: r + Self.halo))

        ctx.drawLayer { s in
            s.clip(to: disc(c, r))
            s.fill(disc(c, r), with: .radialGradient(Gradient(colors: [tint((0.16, 0.08, 0.32), 1), tint((0.03, 0.02, 0.1), 1)]),
                                                     center: c, startRadius: 0, endRadius: r))
            s.blendMode = .plusLighter
            for (i, blob) in blobs.enumerated() {
                let a = p.phase * blob.speed + blob.offset
                let reach = r * (0.3 + 0.25 * e)
                let o = CGPoint(x: c.x + reach * cos(a), y: c.y + reach * sin(a * 1.3 + Double(i)))
                let radius = r * (0.62 + 0.12 * sin(p.phase * 1.7 + Double(i) * 2) + 0.15 * e)
                // Stretched along its own heading: a ribbon of colour rather than a ball.
                var b = s
                b.translateBy(x: o.x, y: o.y)
                b.rotate(by: .radians(a + .pi / 2))
                b.scaleBy(x: 1.35, y: 0.75)
                b.fill(disc(.zero, radius), with: glow(tint(blob.rgb, 0.55 + 0.45 * e), at: .zero, to: radius))
            }
            s.fill(disc(c, r * 0.55), with: glow(.white.opacity(0.4 * e), at: c, to: r * 0.55))
            s.blendMode = .normal
            s.fill(disc(c, r), with: .radialGradient(Gradient(stops: [.init(color: .white.opacity(0), location: 0.78),
                                                                      .init(color: .white.opacity(0.2), location: 1)]),
                                                     center: c, startRadius: 0, endRadius: r))
            let shine = CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.45)
            s.fill(disc(shine, r * 0.45), with: glow(.white.opacity(0.22), at: shine, to: r * 0.45))
        }
    }
}

private struct EffectBackground: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        // An effect view ignores its layer's corner radius; its mask image is what rounds it.
        let side = 2 * radius + 2
        let mask = NSImage(size: CGSize(width: side, height: side), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
