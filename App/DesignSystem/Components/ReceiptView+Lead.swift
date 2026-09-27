import AteKit
import SwiftUI

// MARK: - The dishes lead (round 5, Eamon picked A)

extension ReceiptView {
    /// Every dish in the title face, its score printed like a price at the right, joined by the
    /// receipt's own dot leader. Unrated: no score, and the leader runs to the edge (design rule 7).
    /// A long name wraps to two lines; the score sits on its first.
    var dishLines: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            ForEach(receipt.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                    Text(item.name)
                        .ateText(.receiptLeadDish)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    AteDotLeader()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + ReceiptLeadMetrics.leaderRise }
                    if let score = item.score {
                        Text(ScoreFormat.halfStep(score.value))
                            .ateText(.receiptLeadScore)
                            .monospacedDigit()
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, AteMetrics.hairspace)
    }

    /// The place, in the fine print under the dishes: its name left, its address right — or, on the
    /// Summary's placeless receipt, the Place key where it will print.
    @ViewBuilder
    var placeLine: some View {
        if receipt.place.isEmpty == false {
            HStack(alignment: .firstTextBaseline) {
                Text(receipt.place)
                    .ateText(.receiptLabel)
                    .foregroundStyle(AtePalette.slip.fg)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: AteMetrics.snug)
                if let address = receipt.address {
                    Text(address)
                        .ateText(.receiptLabel)
                        .foregroundStyle(AtePalette.slip.muted)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        } else if let onAddPlace {
            ComposerKey(
                title: "Place",
                icon: .place,
                iconSize: 16,
                background: AtePalette.slip.field,
                foreground: AtePalette.slip.fg,
                identifier: "summary.place",
                action: onAddPlace
            )
            .frame(maxWidth: .infinity)
        }
    }
}

enum ReceiptLeadMetrics {
    /// How far above a dish's baseline its dot leader sits.
    static let leaderRise: CGFloat = 5
}
