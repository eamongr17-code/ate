import AteKit
import SwiftUI

/// What a receipt says. Data only — no formatting decisions, no view types — so the same value can be
/// built from a live entry, from a preview fixture, or from a share export.
struct AteReceipt: Equatable, Identifiable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        var name: String
        /// `nil` is a dish that was named but not scored. Design rule 7: its score column is empty —
        /// no star, no zero.
        ///
        /// There is deliberately no note here. **A receipt prints dish rows and scores only — never a
        /// per-dish quote under a line** (Eamon, 2026-09-26: Share, Summary, statement, anywhere), so
        /// the model cannot carry one for a view to print.
        var score: Rating?
        /// The dish itself — what a save saves, and where a line links to. Absent on a fixture that
        /// has no dish behind it.
        var dishID: UUID?
        /// The viewer's own bookmark. Only ever drawn on somebody else's entry: your own dishes are
        /// written, not saved.
        var isSaved: Bool

        init(
            id: UUID = UUID(),
            name: String,
            score: Rating? = nil,
            dishID: UUID? = nil,
            isSaved: Bool = false
        ) {
            self.id = id
            self.name = name
            self.score = score
            self.dishID = dishID
            self.isSaved = isSaved
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
/// leaders and right-aligned scores — **dish rows and scores only, never a quote under a line** / a
/// dashed rule / order number and date, dish count and average / the barcode / the handle and the
/// wordmark / edge B.
///
/// **Printing** (`SummaryLoading.dc.html`): what is known prints at once — the place, the order
/// number, the date, the handle — and the lines still being sorted are skeleton bars with a slow
/// breath. No words say so.
struct ReceiptView: View {
    let receipt: AteReceipt
    /// The lines are still being sorted: skeleton rows where the items and the count will be.
    var isPrinting = false
    /// …and whether the skeleton breathes. It stops once the wait is over (the sort failed or ran
    /// long) — a bar that pulses forever is a spinner by another name.
    var breathes = true
    /// A receipt that cannot print without a place (the Summary, when the plan is parked): the
    /// place slot is the composer's own Place key, and tapping it attaches one. No words beside it.
    var onAddPlace: (() -> Void)?
    /// How far the place sits from the paper's top edge. 22 on a share card; `Entry` sets 32,
    /// because the words card covers the first sixteen of it.
    var topPadding: CGFloat = 22
    /// `Entry.dc.html` gives its receipt `border-radius:0` — the paper runs out from *under* the
    /// words card, so a rounded top would show as two corners floating in the middle of the page.
    var topRadius: CGFloat = AteMetrics.receiptTop
    /// Present on the entry page, where the header changes the place and a line changes the dish;
    /// absent on a share card, which is a picture.
    var onPlaceTap: (() -> Void)?
    var onItemTap: ((AteReceipt.Item) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: AteMetrics.snug + 2) {
            // A receipt whose place was never named prints without a header rather than a guess
            // (design rule 8).
            if receipt.place.isEmpty == false {
                header
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
            AteDashedRule()
            if isPrinting {
                ReceiptSkeletonLines(breathes: breathes)
            } else {
                lineItems
            }
            AteDashedRule()
            totals
            AteBarcode()
            footer
        }
        .padding(.top, topPadding)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + 2 + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: topRadius)
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
                    .foregroundStyle(AtePalette.slip.muted)
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
            }
        }
    }

    @ViewBuilder
    private func lineItem(_ item: AteReceipt.Item, number: Int) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(String(format: "%02d", number))
                .ateText(.receiptLine)
                .foregroundStyle(AtePalette.slip.muted)
            Text(item.name)
                .ateText(.receiptLine)
                .lineLimit(2)
                // The leader is a greedy Canvas; without this it claims space from the name and a
                // dish that fits on one line wraps anyway.
                .layoutPriority(1)
            AteDotLeader()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            // Unrated: the score column is empty and the leader runs to the edge (design rule 7).
            if let score = item.score {
                Text(ScoreFormat.halfStep(score.value))
                    .ateText(.receiptScore)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
        }
        // `.li` is `line-height:1.65` — the row's box, not the glyphs'. A minimum, not a fixed
        // height: a dish name long enough to wrap grows its row, as a flex row does.
        .frame(minHeight: AteTextStyle.receiptLine.lineBox(dynamicTypeSize))
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
            if isPrinting {
                // `height:15px; justify-content:space-between` — the count and the average, not
                // known until the lines are.
                HStack {
                    ReceiptSkeletonBar(width: 58)
                    Spacer(minLength: AteMetrics.snug)
                    ReceiptSkeletonBar(width: 52)
                }
                .frame(height: 15)
                .ateBreathing(breathes)
            } else {
                HStack {
                    Text(receipt.items.count == 1 ? "1 dish" : "\(receipt.items.count) dishes")
                    Spacer(minLength: AteMetrics.snug)
                    if let average = receipt.average {
                        Text(verbatim: "Avg \(ScoreFormat.entryAverage(average))")
                    }
                }
            }
        }
        .ateText(.receiptLabel)
        .foregroundStyle(AtePalette.slip.fg)
    }

    private var footer: some View {
        HStack {
            Text(verbatim: "@\(receipt.handle)")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.slip.fg)
            Spacer(minLength: AteMetrics.snug)
            AteWordmark(height: AteMetrics.wordmarkFooter)
        }
    }
}

/// The line items while they are being sorted — `SummaryLoading`'s `.skrow`s: the number, the dish,
/// and the score as blank bars, `height:21.5px`, `padding:2px 0 4px`. The third row has no score, as
/// the board draws it: an unrated dish is an empty slot even before it has a name.
private struct ReceiptSkeletonLines: View {
    var breathes: Bool

    /// Name widths, and whether a score bar follows — straight off the board.
    private static let rows: [(name: CGFloat, scored: Bool)] = [(138, true), (74, true), (112, false)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: AteMetrics.snug) {
                    ReceiptSkeletonBar(width: 16)
                    ReceiptSkeletonBar(width: row.name)
                    Spacer(minLength: 0)
                    if row.scored { ReceiptSkeletonBar(width: 22) }
                }
                .frame(height: 21.5)
            }
        }
        .padding(.top, AteMetrics.hairspace)
        .padding(.bottom, AteMetrics.tight)
        .ateBreathing(breathes)
        .accessibilityHidden(true)
    }
}

/// `.sk` — `height:9px; border-radius:5px; background:rgba(36,20,31,.10)`.
private struct ReceiptSkeletonBar: View {
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(AtePalette.slip.fg.opacity(0.10))
            .frame(width: width, height: 9)
    }
}

private struct ReceiptBreathing: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    func body(content: Content) -> some View {
        content
            .opacity(isDim ? AteMotion.breatheLow : 1)
            .onAppear { start() }
            .onChange(of: isOn) { _, _ in start() }
    }

    private func start() {
        guard isOn, reduceMotion == false else {
            withAnimation(.easeOut(duration: 0.2)) { isDim = false }
            return
        }
        withAnimation(AteMotion.breathe) { isDim = true }
    }
}

private extension View {
    /// `@keyframes breathe{50%{opacity:.45}}`, 1.6s ease-in-out, forever — gated on Reduce Motion.
    func ateBreathing(_ isOn: Bool) -> some View {
        modifier(ReceiptBreathing(isOn: isOn))
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
            Item(name: "Tagliatelle al ragù", score: Rating(rounding: 4.5)),
            Item(name: "Tiramisu", score: Rating(rounding: 3)),
            Item(name: "Prawn spaghetti")
        ],
        orderNumber: 142,
        date: Date(timeIntervalSince1970: 1_789_000_000),
        handle: "eamon"
    )

    static let previewSingle = AteReceipt(
        place: "Butchers Diner",
        address: "224 Little Bourke St",
        items: [Item(name: "Cheeseburger", score: Rating(rounding: 4.5))],
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
            ReceiptView(receipt: .preview, onPlaceTap: {}, onItemTap: { _ in })
            ReceiptView(receipt: .previewSingle)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
