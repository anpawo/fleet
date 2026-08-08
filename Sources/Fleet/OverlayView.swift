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
    /// (and a one-session fleet) still centres instead of hugging the left edge.
    private let tilesPerRow = 4
    private let tileWidth: CGFloat = 250
    private let tileSpacing: CGFloat = 18

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
                    ScrollView { grid }
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

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                name
                // Name stays centred in the rectangle; the rest is pinned to the corners
                // and edges around it, so it never shifts as sessions change state.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        path
                        Spacer(minLength: 6)
                        statePill
                    }
                    Spacer(minLength: 0)
                    step
                }
                .padding(11)
            }
            .frame(height: 132)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(session.state.tint, lineWidth: 2.5)
            )
            .shadow(color: session.state.tint.opacity(hovering ? 0.45 : 0.18),
                    radius: hovering ? 16 : 8)
            .scaleEffect(hovering ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var name: some View {
        Text(session.dirName)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 16)
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

    /// Bottom edge: what this session is doing right now, only while it's still doing it.
    @ViewBuilder private var step: some View {
        if let step = session.currentStep {
            Text(step)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(session.state.tint.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
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
