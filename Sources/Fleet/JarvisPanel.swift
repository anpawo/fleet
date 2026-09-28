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
    @Published var capsuleWidth: CGFloat = 180
    @Published var notched = false
    let orb = OrbModel()
    var act: (JarvisPanel.Action) -> Void = { _ in }

    static let capsule: CGFloat = 30, gap: CGFloat = 6, pad: CGFloat = 8, row: CGFloat = 36
    static let rowGap: CGFloat = 2, textX: CGFloat = 34, trail: CGFloat = 12, hint: CGFloat = 22
    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let keywordFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let lineFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    private static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    var panelWidth: CGFloat {
        // The header wraps onto a second line instead: only the options set the width.
        let text = options.reduce(0) { max($0, Self.measure($1.label, Self.labelFont), Self.measure($1.keyword, Self.keywordFont)) }
        return min(max(text + 2 * Self.pad + Self.textX + Self.trail, 360), 560)
    }
    var textWidth: CGFloat { panelWidth - 2 * Self.pad - Self.textX - Self.trail }
    var headerLines: Int { Self.measure(failure ?? line, Self.lineFont) > textWidth ? 2 : 1 }
    var headerHeight: CGFloat { 6 + 14 + 2 + CGFloat(headerLines) * 18 + 6 }
    var panelHeight: CGFloat {
        let n = CGFloat(options.count + 1)
        return 2 * Self.pad + headerHeight + 4 + n * Self.row + (n - 1) * Self.rowGap + (typing ? Self.hint : 0)
    }
    /// How far the capsule reaches up behind the notch: the hardware's own bottom corners are
    /// rounded, and a capsule starting at its edge leaves the desktop showing in them.
    var overlap: CGFloat { notched ? 10 : 0 }
    var width: CGFloat { max(capsuleWidth, panelWidth) }
    var height: CGFloat { overlap + Self.capsule + Self.gap + panelHeight }
}

/// The orb's pose. Driven at 60 Hz by `Jarvis` while the voice plays, still otherwise: a
/// waiting orb costs no frames.
@MainActor
final class OrbModel: ObservableObject {
    enum Mode { case preparing, waiting, silent }
    @Published var scale: CGFloat = 0.85
    @Published var opacity = 0.8
    @Published var angle = 0.0
    @Published var grey = false
    private var clock = 0.0

    func set(_ mode: Mode) {
        scale = 0.85
        grey = mode == .silent
        opacity = mode == .preparing ? 0.6 : mode == .waiting ? 0.8 : 1
    }

    func frame(level: Double, dt: Double, speaking: Bool) {
        clock += dt
        angle += dt * 2 * .pi * (0.25 + 0.5 * level)
        if speaking {
            scale = 0.85 + 0.35 * level
            opacity = 1
        } else {
            // Rendering on the PC: breathe, so the wait reads as work rather than a hang.
            scale = 0.85 * (1 + 0.04 * sin(2 * .pi * clock / 1.6))
            opacity = 0.6
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

/// The capsule out of the notch and the options under it, in one window.
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
        model.capsuleWidth = notch.width
        model.notched = notch.notched
        top = notch.top
        midX = notch.midX
        relayout()
        window.orderFrontRegardless()
        // One turn later, so the view has drawn folded and the springs have somewhere to start.
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    func relayout() {
        window.setFrame(CGRect(x: (midX - model.width / 2).rounded(), y: top + model.overlap - model.height,
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

    /// Where the capsule hangs: flush under the notch, as wide as it; on a screen without one,
    /// a 180 pt pill 4 pt under the menu bar.
    static func notch(of screen: NSScreen) -> (width: CGFloat, notched: Bool, top: CGFloat, midX: CGFloat) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return (width, true, screen.frame.maxY - screen.safeAreaInsets.top,
                    screen.frame.minX + left.width + width / 2)
        }
        return (180, false, screen.visibleFrame.maxY - 4, screen.frame.midX)
    }

    // MARK: - Render

    /// `--render-jarvis <dir>`: every state as a PNG, drawn offscreen under a drawn notch.
    /// A material cannot be captured offscreen — it samples what is behind the window — so
    /// these draw the panel on the window background colour it stands in for.
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
        typealias Scene = (name: String, dark: Bool, notched: Bool, setup: (JarvisModel) -> Void)
        let scenes: [Scene] = [
            ("1-live-dark", true, true, { $0.options = [open]; $0.orb.scale = 1.05; $0.orb.opacity = 1 }),
            ("3-live-dark", true, true, { $0.options = [a, b, open]; $0.queued = 2; $0.orb.scale = 1.1; $0.orb.opacity = 1 }),
            ("3-live-light", false, true, { $0.options = [a, b, open]; $0.queued = 2; $0.orb.scale = 1.1; $0.orb.opacity = 1 }),
            ("6-passive-dark", true, true, { $0.options = [a, b] + more + [open]; $0.live = false; $0.orb.set(.waiting) }),
            ("6-passive-light", false, true, { $0.options = [a, b] + more + [open]; $0.live = false; $0.orb.set(.waiting) }),
            ("typing-dark", true, true, { $0.options = [a, b, open]; $0.typing = true; $0.draft = "also bump the version"; $0.orb.set(.waiting) }),
            ("typing-light", false, true, { $0.options = [a, b, open]; $0.typing = true; $0.draft = "also bump the version"; $0.orb.set(.waiting) }),
            ("novoice-dark", true, true, { $0.options = [a, open]; $0.orb.set(.silent) }),
            ("error-light", false, true, { $0.options = [a, open]; $0.orb.set(.silent)
                $0.failure = "Didn't reach portfolio: the session moved on. Your answer is on the clipboard." }),
            ("pill-dark", true, false, { $0.options = [a, b, open]; $0.orb.scale = 0.95; $0.orb.opacity = 1 }),
        ]
        for scene in scenes {
            let m = JarvisModel()
            m.project = "portfolio"
            m.line = "Portfolio is done, sir."
            m.capsuleWidth = scene.notched ? notchWidth : 180
            m.notched = scene.notched
            m.shown = true
            scene.setup(m)
            let bar: CGFloat = scene.notched ? 32 : 28
            let size = CGSize(width: m.width + 120, height: bar + (scene.notched ? 0 : 4) + m.height + 50)
            let view = VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(scene.dark ? Color(white: 0.16) : Color(white: 0.93))
                    if scene.notched {
                        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).fill(.black)
                            .frame(width: m.capsuleWidth)
                    }
                }
                .frame(height: bar)
                JarvisView(model: m, solid: true).padding(.top, scene.notched ? -m.overlap : 4)
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height)
            .background(scene.dark ? Color(red: 0.12, green: 0.14, blue: 0.2) : Color(red: 0.72, green: 0.78, blue: 0.86))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: size)
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
            capsule
                .offset(y: model.shown ? 0 : -(JarvisModel.capsule + model.overlap))
                .animation(model.shown ? Self.enter : Self.leave, value: model.shown)
                .frame(height: JarvisModel.capsule + model.overlap)
                .clipped()
            panel
                .opacity(model.shown ? 1 : 0)
                .offset(y: model.shown ? 0 : -8)
                .animation(model.shown ? Self.enter.delay(0.06) : Self.leave, value: model.shown)
        }
        .frame(width: model.width, height: model.height, alignment: .top)
    }

    private var capsule: some View {
        let r: CGFloat = 15, top: CGFloat = model.notched ? 0 : r
        return ZStack {
            UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: r,
                                   bottomTrailingRadius: r, topTrailingRadius: top, style: .continuous)
                .fill(.black)
            OrbView(orb: model.orb).padding(.top, model.overlap)
            if model.queued > 0 {
                Text("+\(model.queued)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .padding(.top, model.overlap)
            }
        }
        .frame(width: model.capsuleWidth, height: JarvisModel.capsule + model.overlap)
    }

    private var panel: some View {
        let ink = Color(nsColor: .labelColor)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(height: 14)
                Text(model.failure ?? model.line)
                    .font(Font(JarvisModel.lineFont))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(height: CGFloat(model.headerLines) * 18, alignment: .topLeading)
            }
            .padding(.leading, JarvisModel.textX)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // Centred on the digits' column, level with the project name.
                Button { model.act(.close) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ink.opacity(0.4))
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.plain)
                .padding(.leading, 13.5)
                .padding(.top, 4.5)
            }
            VStack(spacing: JarvisModel.rowGap) {
                ForEach(Array(model.options.enumerated()), id: \.offset) { i, option in
                    OptionRow(model: model, digit: i + 1, option: option)
                }
                OptionRow(model: model, digit: 0, option: nil)
            }
            .padding(.top, 4)
            if model.typing {
                Text("⏎ send     esc back")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.4))
                    .padding(.leading, JarvisModel.textX)
                    .frame(height: JarvisModel.hint)
            }
        }
        .padding(JarvisModel.pad)
        .frame(width: model.panelWidth, height: model.panelHeight, alignment: .top)
        .background {
            if solid { Color(nsColor: .windowBackgroundColor) } else { EffectBackground() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        // A click anywhere on the panel says his attention is here: the digits come back.
        .onTapGesture { model.act(.rearm) }
    }
}

private struct OptionRow: View {
    @ObservedObject var model: JarvisModel
    let digit: Int
    let option: JarvisOption?
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        let label = Color(nsColor: .labelColor)
        let primary = digit == 1
        let field = digit == 0 && model.typing
        let ink = primary ? Color.white : label
        HStack(spacing: 0) {
            Text("\(digit)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(ink.opacity(model.live || field ? 1 : 0.35))
                .frame(width: 24)
            if field {
                TextField("Tell \(model.project) what to do", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { model.act(.submit(model.draft)) }
                    .onAppear { focused = true }
            } else if let option {
                VStack(alignment: .leading, spacing: 1) {
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
                Text("Something else…")
                    .font(.system(size: 13))
                    .foregroundStyle(label.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, JarvisModel.trail)
        .frame(height: JarvisModel.row)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
            primary ? Color(nsColor: .controlAccentColor)
                : field || hover ? label.opacity(0.1) : .clear))
        .opacity(model.typing && !field || model.failure != nil ? 0.35 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.act(digit == 0 ? .type : .pick(digit)) }
    }
}

/// Three soft discs that orbit and swell with the voice. Radial gradients rather than blurred
/// circles: a blur is a filter, and filters are the first thing an offscreen render drops.
private struct OrbView: View {
    @ObservedObject var orb: OrbModel

    var body: some View {
        let colors: [NSColor] = orb.grey ? [.white, .white, .white] : [.systemCyan, .systemPurple, .systemPink]
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let a = orb.angle + Double(i) * 2 * .pi / 3
                let c = Color(nsColor: colors[i]).opacity(orb.grey ? 0.2 : 1)
                Circle()
                    .fill(RadialGradient(stops: [.init(color: c, location: 0), .init(color: c.opacity(0.7), location: 0.45),
                                                 .init(color: c.opacity(0), location: 1)],
                                         center: .center, startRadius: 0, endRadius: 8))
                    .frame(width: 16, height: 16)
                    .offset(x: 2.5 * cos(a), y: 2.5 * sin(a))
                    .blendMode(.plusLighter)
            }
        }
        .compositingGroup()
        .frame(width: 20, height: 20)
        .scaleEffect(orb.scale)
        .opacity(orb.opacity)
    }
}

private struct EffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        // An effect view ignores its layer's corner radius; its mask image is what rounds it.
        let mask = NSImage(size: CGSize(width: 34, height: 34), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
