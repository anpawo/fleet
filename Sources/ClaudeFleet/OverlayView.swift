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

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 430), spacing: 18)]

    var body: some View {
        ZStack {
            // Flat scrim rather than a live blur: a full-screen material is continuous GPU
            // work, and this panel exists to save power.
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.hidePanel() }

            VStack(spacing: 22) {
                header

                if eagerLayout {
                    grid
                } else {
                    ScrollView { grid }
                }
            }
            .padding(.top, 46)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(controller.sessions) { session in
                SessionTile(session: session) {
                    controller.activate(session)
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 44)
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

/// One session: directory, topic, a rendered slice of the conversation, state border.
struct SessionTile: View {
    let session: Session
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                titleBlock
                Divider().overlay(Color.white.opacity(0.08))
                preview
                footer
            }
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

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.dirName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(session.state.label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(session.state.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(session.state.tint.opacity(0.14),
                                in: Capsule())
            }

            Text(session.displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .truncationMode(.head)

            Text(session.topic)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    /// The conversation, drawn from the transcript. Cheaper and more legible at this size
    /// than a scaled-down screen capture, and it needs no screen-recording permission.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            let lines = session.transcript?.preview ?? []
            if lines.isEmpty {
                Text("No conversation yet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(lines.suffix(7)) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(glyph(for: line.kind))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(line.kind == .tool ? 0.42 : 0.66))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.black.opacity(0.45))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // verbatim: a pid is an identifier, not a number to be group-separated.
            Text(verbatim: "pid \(session.proc.pid)")
            if let tty = session.proc.tty {
                Text(tty.replacingOccurrences(of: "/dev/", with: ""))
            }
            Spacer()
            if session.state == .running, session.cpuPercent >= 1 {
                Text(String(format: "%.0f%% cpu", session.cpuPercent))
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func glyph(for kind: PreviewLine.Kind) -> String {
        switch kind {
        case .user: return ">"
        case .assistant: return "*"
        case .tool: return "-"
        }
    }

    private func color(for kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .user: return Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.8)
        case .assistant: return Color(red: 0.95, green: 0.62, blue: 0.38).opacity(0.85)
        case .tool: return .white.opacity(0.28)
        }
    }
}
