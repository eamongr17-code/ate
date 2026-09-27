import AteKit
import SwiftUI

extension ReceiptView {
    // MARK: - Round 5 exploration: the dishes lead

    /// `-ate-r5-receipt A|B`; `nil` is today's receipt, the place as its title.
    static let lead = AteExplore.receipt

    /// **A** — every dish in the title face with its score printed like a price, joined by the
    /// receipt's own dot leader. Unrated: the leader runs to the edge.
    var leadDishes: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            ForEach(receipt.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                    Text(item.name)
                        .ateText(.receiptLeadDish)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    AteDotLeader()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
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

    /// **B** — the bill itself at the head of the ticket: numbered mono lines, larger.
    var ticketLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(receipt.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                    Text(String(format: "%02d", index + 1))
                        .ateText(.receiptTicketLine)
                        .foregroundStyle(AtePalette.slip.muted)
                        .fixedSize()
                    Text(item.name)
                        .ateText(.receiptTicketLine)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    AteDotLeader()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                    if let score = item.score {
                        Text(ScoreFormat.halfStep(score.value))
                            .ateText(.receiptTicketScore)
                            .monospacedDigit()
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .frame(minHeight: AteTextStyle.receiptTicketLine.lineBox(dynamicTypeSize))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The place, under the dishes: a line of fine print — the place left, its address right (A),
    /// or the pin, the place and its address under it (B). The Summary's Place key when there is none.
    @ViewBuilder
    var placeSlot: some View {
        if receipt.place.isEmpty == false {
            if Self.lead == "A" {
                HStack(alignment: .firstTextBaseline) {
                    Text(receipt.place)
                        .ateText(.receiptLabel)
                        .foregroundStyle(AtePalette.slip.fg)
                        .lineLimit(1)
                    Spacer(minLength: AteMetrics.snug)
                    if let address = receipt.address {
                        Text(address)
                            .ateText(.receiptLabel)
                            .foregroundStyle(AtePalette.slip.muted)
                            .lineLimit(1)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: AteMetrics.snug - 2) {
                    AteIcon.place.view(size: 14)
                        .foregroundStyle(AtePalette.slip.fg)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(receipt.place)
                            .ateText(.receiptTicketPlace)
                            .foregroundStyle(AtePalette.slip.fg)
                        if let address = receipt.address {
                            Text(address)
                                .ateText(.receiptLabel)
                                .foregroundStyle(AtePalette.slip.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            addPlaceKey
        }
    }
}
