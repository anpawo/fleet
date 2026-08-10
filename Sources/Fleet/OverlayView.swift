import SwiftUI

extension SessionState {
    var tint: Color {
        switch self {
        case .running: return Color(red: 1.00, green: 0.35, blue: 0.32)
        case .ready: return Color(red: 0.24, green: 0.82, blue: 0.35)
        case .awaitingAnswer: return Color(red: 0.27, green: 0.62, blue: 1.00)
        }
    }

    var label: String {
        switch self {
        case .running: return "WORKING"
        case .ready: return "READY"
        case .awaitingAnswer: return "NEEDS YOU"
        }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: AppController
    /// Offscreen `ImageRenderer` passes never materialise lazy content inside a ScrollView,
    /// so `--render` drops the scroll container to draw every tile.
    var eagerLayout = false

    /// Fixed tiles per row and fixed width, rather than adaptive, so a partial last row
    /// (and a one-session fleet) still centres instead of hugging the left edge. Exactly four
    /// sessions get a 2x2 square instead of a 3 + orphan, which reads as unfinished.
    private var tilesPerRow: Int {
        controller.sessions.count == 4 ? 2 : 3
    }
    private let tileWidth: CGFloat = 310
    /// Wider than it looks like it needs to be: the hover glow is a 16pt shadow, and the
    /// neighbouring tile is opaque and drawn after, so a tighter gap eats the glow.
    private let tileSpacing: CGFloat = 26

    var body: some View {
        ZStack {
            // Flat scrim rather than a live blur: a full-screen material is continuous GPU
            // work, and this panel exists to save power.
            Color.black.opacity(0.68)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                header

                if eagerLayout {
                    grid
                } else {
                    // Rows past the bottom of the screen scroll into view rather than being
                    // squeezed; with a fleet that fits, `basedOnSize` keeps it from bouncing.
                    ScrollView(.vertical) { grid }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: .infinity)
                        .background(dismissLayer)
                }
            }
            .padding(.top, 46)
        }
        // Anything not claimed by a tile dismisses, matching Esc. Tiles are Buttons and
        // consume their own taps, so this only fires on the surrounding space.
        .contentShape(Rectangle())
        .onTapGesture { controller.hidePanel() }
    }

    /// A ScrollView claims hit-testing across its whole area, so taps landing in the gaps
    /// between tiles never reach the outer gesture. This puts a dismiss target behind them.
    private var dismissLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { controller.hidePanel() }
    }

    private var rows: [[Session]] {
        stride(from: 0, to: controller.sessions.count, by: tilesPerRow).map {
            Array(controller.sessions[$0 ..< min($0 + tilesPerRow, controller.sessions.count)])
        }
    }

    private var grid: some View {
        VStack(spacing: tileSpacing) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: tileSpacing) {
                    ForEach(row) { session in
                        SessionTile(session: session) {
                            controller.activate(session)
                        }
                        .frame(width: tileWidth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        // Room for the glow on the top row — the ScrollView clips to its bounds, and the
        // shadow reaches 16pt out on hover.
        .padding(.top, 26)
        .padding(.bottom, 44)
        .background(dismissLayer)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Claude Code")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3.2)
                .foregroundStyle(.white.opacity(0.45))

            Text(summary)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 18) {
                legend(.awaitingAnswer)
                legend(.ready)
                legend(.running)
            }
            .padding(.top, 4)

            Text("Click a session to jump to its terminal  ·  Esc to dismiss")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.top, 2)
        }
    }

    private var summary: String {
        let n = controller.sessions.count
        let waiting = controller.sessions.filter { $0.state == .awaitingAnswer }.count
        if waiting > 0 {
            return "\(waiting) of \(n) need\(waiting == 1 ? "s" : "") your input"
        }
        return n == 1 ? "1 session running" : "\(n) sessions running"
    }

    private func legend(_ state: SessionState) -> some View {
        HStack(spacing: 6) {
            Circle().fill(state.tint).frame(width: 7, height: 7)
            Text(state.label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// One session, read at a glance: the name, the state border, and — only while it is
/// working — the single step in flight. Everything else is a distraction at this size;
/// `--scan` is there when you want the details.
struct SessionTile: View {
    let session: Session
    let onSelect: () -> Void

    @State private var hovering = false

    /// Fixed so the name's 30% line is the same on every tile, whatever the history under it.
    private static let height: CGFloat = 186
    /// Roughly the name's line height at its font size, to centre it on that 30% mark.
    /// Tracks `name`'s point size — if one moves the other has to.
    private static let nameLine: CGFloat = 37

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    // The name sits with its centre 30% down the tile, so every tile's name
                    // lands on the same line however much history is under it.
                    Spacer().frame(height: Self.height * 0.30 - Self.nameLine / 2)
                    name
                    // The space above flexes and the space below is fixed, so the history sits
                    // low in the tile — anchored near the bottom edge rather than centred
                    // between it and the name.
                    Spacer(minLength: 8)
                    rail
                    step
                    Spacer().frame(height: 12)
                }
                .padding(12)
                // Without this the stack is only as tall as its content, the flexible spacer
                // above the history has nothing to expand into, and the slack ends up below
                // the tile's content instead of above it — which is why the history sat high
                // whatever the spacers said.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                HStack(alignment: .top, spacing: 8) {
                    path
                    Spacer(minLength: 6)
                    statePill
                }
                .padding(11)
            }
            .frame(height: Self.height, alignment: .top)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(session.state.tint, lineWidth: 2.5)
            )
            // Order matters. `scaleEffect` renders the card into an offscreen buffer sized to
            // its own bounds, so a shadow applied *before* it gets baked into that buffer and
            // clipped off at the card's edges — which is exactly the sliced-off glow you see
            // on hover. Grouping first, scaling, then casting the shadow keeps it outside.
            .compositingGroup()
            .scaleEffect(hovering ? 1.015 : 1.0)
            .shadow(color: session.state.tint.opacity(hovering ? 0.45 : 0.18),
                    radius: hovering ? 16 : 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var name: some View {
        Text(session.dirName)
            .font(.system(size: 31, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The session's recent history, oldest at the top: what you asked, what it ran, what it
    /// said back. One line each — the sequence is the point, not any single line's detail.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 3) {
            let lines = session.steps.suffix(Config.railLineCount)
            if lines.isEmpty {
                Text("No conversation yet")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            } else {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(glyph(for: line.kind))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint(for: line.kind))
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(line.kind == .tool ? 0.45 : 0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        // No trailing spacer: the rail must stay exactly as tall as its lines, or it absorbs
        // the tile's slack itself and the spacers positioning it have nothing left to give.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func glyph(for kind: PreviewLine.Kind) -> String {
        switch kind {
        case .user: return ">"
        case .assistant: return "*"
        case .tool: return "-"
        }
    }

    private func tint(for kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .user: return Color(red: 0.42, green: 0.70, blue: 1.00)
        case .assistant: return .white.opacity(0.5)
        case .tool: return .white.opacity(0.3)
        }
    }

    /// Top left, and only when it says something the name doesn't already — a project sitting
    /// at ~/self/<name> gets nothing here.
    @ViewBuilder private var path: some View {
        if let path = session.subPath {
            Text(path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// Pinned under the rail: the step still in flight, which by definition has no result yet
    /// and so never appears in the history above it.
    @ViewBuilder private var step: some View {
        if let step = session.currentStep {
            HStack(alignment: .top, spacing: 6) {
                Text("»")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(step)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(session.state.tint.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statePill: some View {
        Text(session.state.label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(session.state.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(session.state.tint.opacity(0.14), in: Capsule())
    }
}
