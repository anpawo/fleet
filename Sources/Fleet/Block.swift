import SwiftUI

/// Every block on the panel: a title bar, a body, and the frame round both. MEMORY, REELS,
/// MAIL, EPITECH, the fleet, CRONS, TODO and ALERT are all this, and none of them draws a
/// border, a ground or a heading of its own — asked for on 2026-09-27, after four blocks were
/// found each drawing their frame by hand.
///
/// The title bar is the name on its chip at the left, `trailing` at the right (a count, a
/// readout, a +), and `middle` centred over the line without taking any of its height (a
/// verdict, a spinner, the fleet's key). The name sits 10pt from the frame on top and on the
/// left whatever `spread` the block asks for.
struct Block<Middle: View, Trailing: View, Content: View>: View {
    let title: String
    var icon: String?
    var titleColor: Color = .white.opacity(0.92)
    var tracking: CGFloat = 3.2
    /// The outline, and the wash inside it unless `fill` says otherwise — see `blockFrame`.
    let tint: Color
    var fill: Color?
    var spread: CGFloat = 13
    var bottomSpread: CGFloat?
    /// A gauge filled from the left instead of a flat wash — MEMORY's RAM.
    var level: BlockLevel?
    /// Between the title bar and the body.
    var bodyGap: CGFloat = 9
    /// `middle` halfway between the name and `trailing` rather than centred on the whole bar —
    /// MEMORY's warning, whose readout is wide enough to pull the bar's centre onto it.
    var middleBetween = false
    @ViewBuilder var middle: () -> Middle
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: bodyGap) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 11, weight: .bold))
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(tracking)
                }
                .foregroundStyle(titleColor)
                .titleGround()
                Spacer(minLength: 3)
                if middleBetween {
                    middle()
                    Spacer(minLength: 3)
                }
                trailing()
            }
            // The chips' ground hangs 7pt past the words: this leaves 10pt of pane round them,
            // the frame reaching `spread` past the block.
            .padding(.horizontal, 17 - spread)
            .overlay { if !middleBetween { middle() } }
            content()
        }
        .blockFrame(tint, fill: fill, spread: spread, bottomSpread: bottomSpread, level: level)
    }
}

/// How full a gauge block is, and in what colour.
struct BlockLevel: Equatable {
    var share: Double
    var tint: Color
}
