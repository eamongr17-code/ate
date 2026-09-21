import AteKit
import SwiftUI

/// What a receipt says. Data only — no formatting decisions, no view types — so the same value can be
/// built from a live entry, from a preview fixture, or from a share export.
struct AteReceipt: Equatable, Identifiable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        var name: String
        /// `nil` is a dish that was named but not scored. Design rule 7: it prints as an empty star
        /// and never as a zero.
        var score: Rating?
        /// The sentence the sorter lifted out of the person's own words for this dish.
        var note: String?

        init(id: UUID = UUID(), name: String, score: Rating? = nil, note: String? = nil) {
            self.id = id
            self.name = name
            self.score = score
            self.note = note
        }
    }

    let id: UUID
    var place: String
    var placeID: UUID?
    var address: String?
    var items: [Item]
    /// The entry's number in the person's own sequence — `#0142`. Printed, not computed here.
    var orderNumber: Int
    var date: Date
    var handle: String

    init(
        id: UUID = UUID(),
        place: String,
        placeID: UUID? = nil,
        address: String? = nil,
        items: [Item],
        orderNumber: Int,
        date: Date,
        handle: String
    ) {
        self.id = id
        self.place = place
        self.placeID = placeID
        self.address = address
        self.items = items
        self.orderNumber = orderNumber
        self.date = date
        self.handle = handle
    }

    /// How a receipt writes its date: "Sat 19 Sep 2026". The ORDER is the design's and is fixed; the
    /// weekday and month NAMES still come from the reader's locale.
    static let dateFormat = Date.VerbatimFormatStyle(
        format: """
\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)
""",
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )

    /// The mean of the dishes that were actually scored. Unscored dishes are not zeros and are not
    /// counted.
    var average: Double? {
        let scores = items.compactMap(\.score?.value)
        guard scores.isEmpty == false else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}

/// **The receipt.** What Ate prints (design rule 4), and the one component the entry page and the
/// share card both show — identically. If it looks different in the two places, that is a bug in the
/// container, not a reason for a second component.
///
/// Its parts, in order: the place and its address / a dashed rule / numbered line items with dot
/// leaders and right-aligned scores, each dish's note quoted in italic beneath it / a dashed rule /
/// order number and date, dish count and average / the barcode / the handle and the wordmark / the
/// torn bottom edge.
///
/// Named `AteReceiptView` only because the old app's `App/Features/Log/ReceiptView.swift` still
/// compiles alongside it; it takes the plain name in the change that deletes the old root.
struct AteReceiptView: View {
    let receipt: AteReceipt
    /// Extra room at the top, for when something overlaps the paper (the entry page's words card).
    var additionalTopInset: CGFloat = 0
    /// Present on the entry page, where the header changes the place and a line changes the dish;
    /// absent on a share card, which is a picture.
    var onPlaceTap: (() -> Void)?
    var onItemTap: ((AteReceipt.Item) -> Void)?

    var body: some View {
        VStack(spacing: AteMetrics.snug + 2) {
            header
            AteDashedRule()
            lineItems
            AteDashedRule()
            totals
            AteBarcode()
            footer
        }
        .padding(.top, 22 + additionalTopInset)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + 2 + AteMetrics.tornEdgeHeight)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }

    // MARK: - Bands

    @ViewBuilder
    private var header: some View {
        let content = VStack(spacing: AteMetrics.tight) {
            Text(receipt.place)
                .ateText(.receiptPlace)
                .multilineTextAlignment(.center)
            if let address = receipt.address {
                Text(address)
                    .ateText(.receiptLabel)
                    .foregroundStyle(AtePalette.paper.muted)
            }
        }
        .frame(maxWidth: .infinity)

        if let onPlaceTap {
            Button(action: onPlaceTap) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(receipt.place). Change the place")
        } else {
            content
        }
    }

    private var lineItems: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(receipt.items.enumerated()), id: \.element.id) { index, item in
                lineItem(item, number: index + 1)
                if let note = item.note {
                    Text(verbatim: "\u{201C}\(note)\u{201D}")
                        .ateText(.proseNote)
                        .foregroundStyle(AtePalette.paper.muted)
                        .padding(.leading, 26)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func lineItem(_ item: AteReceipt.Item, number: Int) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(String(format: "%02d", number))
                .ateText(.receiptLine)
                .foregroundStyle(AtePalette.paper.muted)
            Text(item.name)
                .ateText(.receiptLine)
                .lineLimit(2)
                // The leader is a greedy Canvas; without this it claims space from the name and a
                // dish that fits on one line wraps anyway.
                .layoutPriority(1)
            AteDotLeader()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            if let score = item.score {
                Text(ScoreFormat.halfStep(score.value))
                    .ateText(.receiptScore)
                    .monospacedDigit()
                    .layoutPriority(1)
            } else {
                UnscoredMark()
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            }
        }
        .accessibilityElement(children: .combine)

        if let onItemTap {
            Button { onItemTap(item) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Change the dish")
        } else {
            row
        }
    }

    private var totals: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "Order #\(String(format: "%04d", receipt.orderNumber))")
                Spacer(minLength: AteMetrics.snug)
                Text(receipt.date.formatted(AteReceipt.dateFormat))
            }
            HStack {
                Text(receipt.items.count == 1 ? "1 dish" : "\(receipt.items.count) dishes")
                Spacer(minLength: AteMetrics.snug)
                if let average = receipt.average {
                    Text(verbatim: "Avg \(average.formatted(.number.precision(.fractionLength(0...2))))")
                }
            }
        }
        .ateText(.receiptLabel)
        .foregroundStyle(AtePalette.paper.fg)
    }

    private var footer: some View {
        HStack {
            Text(verbatim: "@\(receipt.handle)")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.fg)
            Spacer(minLength: AteMetrics.snug)
            AteWordmark(height: AteMetrics.wordmarkFooter)
        }
    }
}

// Fixtures are `DEBUG || BETA`, not `DEBUG`: the debug gallery ships to TestFlight, and a component
// that can't be shown there is a component nobody can judge. Previews stay `DEBUG`.
#if DEBUG || BETA
extension AteReceipt {
    /// The prototype's own receipt, so a preview and the design can be held side by side.
    static let preview = AteReceipt(
        place: "Tipo 00",
        address: "361 Little Bourke St",
        items: [
            Item(name: "Tagliatelle al ragù", score: Rating(rounding: 4.5),
                 note: "Unreal. Rich, glossy, gone in four minutes."),
            Item(name: "Tiramisu", score: Rating(rounding: 3), note: "A bit flat after that."),
            Item(name: "Prawn spaghetti")
        ],
        orderNumber: 142,
        date: Date(timeIntervalSince1970: 1_789_000_000),
        handle: "eamon"
    )

    static let previewSingle = AteReceipt(
        place: "Butchers Diner",
        address: "224 Little Bourke St",
        items: [Item(name: "Cheeseburger", score: Rating(rounding: 4.5), note: "Would queue again.")],
        orderNumber: 143,
        date: Date(timeIntervalSince1970: 1_789_200_000),
        handle: "eamon"
    )
}
#endif

#if DEBUG
#Preview("Receipt") {
    ScrollView {
        VStack(spacing: AteMetrics.section) {
            AteReceiptView(receipt: .preview, onPlaceTap: {}, onItemTap: { _ in })
            AteReceiptView(receipt: .previewSingle)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
