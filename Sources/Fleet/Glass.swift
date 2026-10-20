import SwiftUI

/// The panel's glass since 2026-10-20, Echo's (my-lab/echo), which is the reconciliation site's
/// `backdrop-filter: blur(40px) saturate(200%) brightness(1.15)`, on what is behind the window:
/// a behind-window effect view whose backdrop layer takes those filters, its own tints hidden.
/// macOS's own blur has one radius; the private CAFilter on the backdrop layer is how Echo dials
/// it, measured there through CARenderer. Echo's glass is light; the panel's stays dark, its
/// blocks' colours washed over it (asked the same day, the light one tried and dropped).
final class Glass: NSVisualEffectView {
    /// How dark the panel sits over your desktop: the veil's black. Lower shows more of what is
    /// behind it.
    static let dim = 0.6
    /// How much of a block's colour lies over its glass: the rest is the blur.
    static let wash = 0.72
    static let radius: CGFloat = 12

    /// CSS `saturate(200%) brightness(1.15)` on sRGB values, rows R, G, B. Times the veil's
    /// light first: the glass stands on the veil and shows the screen through it.
    static let matrix: [[Double]] = {
        let s = 2.0
        return [[0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]].map { $0.map { $0 * (1 - dim) * 1.15 } }
    }()

    static func filtered(_ color: Color) -> Color {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
        let out = matrix.map { row in min(1, max(0, zip(row, v).map(*).reduce(0, +))) }
        return Color(.sRGB, red: out[0], green: out[1], blue: out[2])
    }

    let blur: Double
    /// Nil: the blur alone.
    let tone: [[Double]]?

    /// Nil when QuartzCore no longer has the private filters: the system's own blur stays.
    func filters() -> [NSObject]? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        func make(_ name: String) -> NSObject? {
            type.perform(NSSelectorFromString("filterWithType:"), with: name)?.takeUnretainedValue() as? NSObject
        }
        guard let gauss = make("gaussianBlur") else { return nil }
        gauss.setValue("cssBlur", forKey: "name")
        gauss.setValue(blur, forKey: "inputRadius")
        gauss.setValue(true, forKey: "inputNormalizeEdges")
        guard let tone else { return [gauss] }
        guard let colour = make("colorMatrix") else { return nil }
        // Four rows of five, as CAColorMatrix holds them: the R, G, B and A weights, then an offset.
        var m = tone.flatMap { row -> [Float] in row.map { Float($0) } + [0, 0] } + [0, 0, 0, 1, 0]
        colour.setValue(NSValue(bytes: &m, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
        return [gauss, colour]
    }

    init(blur: Double, tone: [[Double]]?, radius r: CGFloat) {
        self.blur = blur
        self.tone = tone
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .active
        guard r > 0 else { return }
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        maskImage = mask
    }

    required init?(coder: NSCoder) { nil }

    private static var warned = false

    override func updateLayer() { super.updateLayer(); takeFilters() }
    override func layout() { super.layout(); takeFilters() }

    /// The material's layer holds the backdrop and the tints over it: the tints go, the backdrop
    /// takes the site's filters after the system's HDR one. Done again whenever the view
    /// rebuilds them.
    ///
    /// The backdrop is `backdrop` in a dark appearance and `Backdrop` in a light one: matched on
    /// the exact name, as Echo does, it was hidden with the tints the day the panel was light,
    /// and the glass showed the screen as it is (2026-10-20). Not found, the system's material
    /// stays whole rather than nothing.
    private func takeFilters() {
        let layers = layer?.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
        guard let backdrop = layers.first(where: { $0.name?.lowercased() == "backdrop" }) else {
            if !layers.isEmpty, !Self.warned {
                Self.warned = true
                NSLog("Fleet: no backdrop among the glass's layers \(layers.map { $0.name ?? "-" })")
            }
            return
        }
        for sub in layers where sub !== backdrop { sub.isHidden = true }
        let names = (backdrop.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String }
        guard !names.contains("cssBlur"), let css = filters() else { return }
        backdrop.filters = (backdrop.filters ?? []).filter { ($0 as? NSObject)?.value(forKey: "name") as? String == "sdrNormalize" } + css
    }
}

private struct GlassView: NSViewRepresentable {
    let blur: Double
    let tone: [[Double]]?
    let radius: CGFloat
    func makeNSView(context: Context) -> Glass { Glass(blur: blur, tone: tone, radius: radius) }
    func updateNSView(_ view: Glass, context: Context) {}
}

/// What a render stands on: a gradient over the whole picture, top to bottom. Nil on the screen.
struct Backdrop {
    var colors: [Color]
    var size: CGSize

    /// His wallpaper's kind of light, as Echo's renders have it, a dark desktop, or a white
    /// window (his terminal).
    static func named(_ name: String, size: CGSize) -> Backdrop {
        let colors: [String: [Color]] = [
            "dark": [Color(red: 0.05, green: 0.15, blue: 0.40), Color(red: 0.10, green: 0.30, blue: 0.60)],
            "white": [.white, .white],
        ]
        return Backdrop(colors: colors[name] ?? [Color(red: 0.55, green: 0.70, blue: 0.85),
                                                 Color(red: 0.85, green: 0.82, blue: 0.70)],
                        size: size)
    }
}

private struct RenderBackdrop: EnvironmentKey { static let defaultValue: Backdrop? = nil }

extension EnvironmentValues {
    var renderBackdrop: Backdrop? {
        get { self[RenderBackdrop.self] }
        set { self[RenderBackdrop.self] = newValue }
    }
}

/// A block's glass: what is behind the window, through the site's filters. In a render nothing is
/// behind, so the render's own backdrop goes through the same matrix in its place (a blur leaves a
/// vertical gradient as it is).
struct FrostedGlass: View {
    @Environment(\.renderBackdrop) private var renderBackdrop

    var body: some View {
        if let renderBackdrop {
            GeometryReader { g in
                let at = g.frame(in: .global)
                LinearGradient(colors: renderBackdrop.colors.map(Glass.filtered), startPoint: .top, endPoint: .bottom)
                    .frame(width: renderBackdrop.size.width, height: renderBackdrop.size.height)
                    .offset(x: -at.minX, y: -at.minY)
            }
        } else {
            // Twice Echo's 40: at 40 a YouTube page behind the fleet still showed the video's
            // frame against the thumbnails beside it, a faint square in the glass (2026-10-20).
            GlassView(blur: 80, tone: Glass.matrix, radius: Glass.radius)
        }
    }
}

/// The site's overlay under its dialog, over the whole screen: what is behind blurred 4 pt
/// (`backdrop-blur-xs`) under black — 0.3 on the site, `Glass.dim` here.
struct Veil: View {
    @Environment(\.renderBackdrop) private var renderBackdrop

    var body: some View {
        ZStack {
            if renderBackdrop == nil { GlassView(blur: 4, tone: nil, radius: 0) }
            Color.black.opacity(Glass.dim)
        }
    }
}
