import SwiftUI

/// **New list, on the shelf** (build 92 feedback) — the first thing on the Lists shelf, always: a
/// dashed outline at the list card's radius, the height of a card's top band, the list-plus glyph
/// and "New list" in the add row's voice. Paper, not colour, so it never competes with a real card.
/// The dash is the scoring row's empty slot (1.5pt, 4/3, ink at 30%).
struct AteNewListCard: View {
    let title: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.regular) {
                AteIcon.listPlus.view(size: AteChoiceRowMetrics.icon)
                Text(title).ateText(.control)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.fg)
            .padding(.leading, AteListCardMetrics.leading)
            .padding(.trailing, AteListCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: AteNewListCardMetrics.height)
            .overlay {
                RoundedRectangle(cornerRadius: AteListCardMetrics.radius, style: .continuous)
                    .strokeBorder(
                        palette.fg.opacity(AteNewListCardMetrics.dashOpacity),
                        style: StrokeStyle(lineWidth: AteNewListCardMetrics.dashLine, dash: AteNewListCardMetrics.dash)
                    )
            }
            .contentShape(.rect(cornerRadius: AteListCardMetrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "lists.newCard")
    }
}

enum AteNewListCardMetrics {
    /// A list card's top band: its 16 top padding over the 58pt photo cluster.
    static let height: CGFloat = AteListCardMetrics.padding + AteListCardMetrics.photo
    /// The scoring row's empty slot: `1.5px dashed`, 4 on 3, ink at 30%.
    static let dashLine: CGFloat = 1.5
    static let dash: [CGFloat] = [4, 3]
    static let dashOpacity = 0.3
}
