import AteKit
import SwiftUI

/// **A dish row waiting for a score** — the prefilled composer's rows ("Ate with", `ate-with.html`
/// section 3): the slip's own dish row (``SlipDishRow``: the name at 20, the score printed like a
/// price), and while it has no score an empty dashed slot where the score will print (`.slot`). The
/// row the score slide is on sits on the ground colour, rounded (`.cur`). A tap on any row puts the
/// slide back on it.
///
/// `.slot{width:54px; height:30px; border-radius:999px; border:1.5px dashed rgba(ink,.3)}`;
/// `.cur{background:ground; border-radius:16px; margin:0 -12px; padding:0 12px}`;
/// `.dish{min-height:44px; padding:9px 0; border-top:1px hair}`, none above the first or around `.cur`.
struct AteScoringDishRow: View {
    let dishID: UUID
    let name: String
    let score: Rating?
    var isCurrent = false
    /// The hairline above: off for the first row, and on either side of the current one.
    var showsRule = true
    let onSelect: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        SlipDishRow(
            dish: AteSlip.Dish(id: dishID, dishID: dishID, name: name, score: score),
            action: onSelect,
            identifier: "respond"
        )
        .overlay(alignment: .trailing) {
            if score == nil {
                Capsule()
                    .strokeBorder(
                        palette.fg.opacity(AteScoringDishRowMetrics.slotOpacity),
                        style: StrokeStyle(lineWidth: AteScoringDishRowMetrics.slotLine,
                                           dash: AteScoringDishRowMetrics.slotDash)
                    )
                    .frame(width: AteScoringDishRowMetrics.slotWidth, height: AteScoringDishRowMetrics.slotHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, AteScoringDishRowMetrics.padding)
        .padding(.horizontal, AteScoringDishRowMetrics.currentInset)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: AteScoringDishRowMetrics.currentRadius, style: .continuous)
                    .fill(AteColor.ground)
            }
        }
        .overlay(alignment: .top) {
            if showsRule && isCurrent == false {
                AteHairline().padding(.horizontal, AteScoringDishRowMetrics.currentInset)
            }
        }
        .accessibilityValue(score == nil ? "Not scored" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

enum AteScoringDishRowMetrics {
    static let slotWidth: CGFloat = 54
    static let slotHeight: CGFloat = 30
    static let slotLine: CGFloat = 1.5
    static let slotDash: [CGFloat] = [4, 3]
    static let slotOpacity = 0.3
    /// `.dish{padding:9px 0}` around the slip row's own 44 (the board has no `box-sizing`, so the
    /// padding adds to the min-height: a 62 row).
    static let padding: CGFloat = 9
    /// `.cur{margin:0 -12px; padding:0 12px}`: the ground reaches 12 past the column.
    static let currentInset: CGFloat = 12
    static let currentRadius: CGFloat = 16
}
