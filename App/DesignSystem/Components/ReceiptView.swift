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
    /// "Ate with": the handles the signature line adds — "@eamon with @jess", "with @jess +1"
    /// (`ate-with.html` 1e). Empty prints the signature alone.
    var companions: [String] = []

    init(
        id: UUID = UUID(),
        place: String,
        placeID: UUID? = nil,
        address: String? = nil,
        items: [Item],
        orderNumber: Int,
        date: Date,
        handle: String,
        companions: [String] = []
    ) {
        self.id = id
        self.place = place
        self.placeID = placeID
        self.address = address
        self.items = items
        self.orderNumber = orderNumber
        self.date = date
        self.handle = handle
        self.companions = companions
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
/// Its parts, in order (round 5 — **the dishes lead**, the place is fine print): the dishes in the
/// title face with dot leaders and right-aligned scores — **dish rows and scores only, never a quote
/// under a line** / a dashed rule / the place left, its address right / a dashed rule / order number
/// and date, dish count and average / the handle and the wordmark / edge B.
///
/// **Printing** (`SummaryLoading.dc.html`): what is known prints at once — the place, the order
/// number, the date, the handle — and the dishes still being sorted are skeleton bars with a slow
/// breath, at the dishes' own rhythm. No words say so.
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
    /// How far the first dish sits from the paper's top edge — `Share.dc.html`'s 22.
    var topPadding: CGFloat = 22

    var body: some View {
        VStack(spacing: AteMetrics.snug + 2) {
            // The dishes lead (round 5, Eamon: heroing the restaurant "goes against the thesis of
            // the app"). The place is one line of fine print under them, never the title.
            if isPrinting {
                ReceiptSkeletonLines(breathes: breathes)
            } else {
                dishLines
            }
            AteDashedRule()
            placeLine
            AteDashedRule()
            totals
            footer
        }
        .padding(.top, topPadding)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + 2 + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: AteMetrics.receiptTop)
    }

    // MARK: - Bands

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
            signature
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.slip.fg)
                .lineLimit(1)
            Spacer(minLength: AteMetrics.snug)
            AteWordmark(height: AteMetrics.wordmarkFooter)
        }
    }

    /// "@eamon", or "@eamon with @jess +1" — the same mono fine print, "with" muted.
    private var signature: Text {
        var line = AttributedString("@\(receipt.handle)")
        if let with = CompanionLine.compact(receipt.companions) {
            var word = AttributedString(" with ")
            word.foregroundColor = AtePalette.slip.muted
            line += word + AttributedString(with)
        }
        return Text(line)
    }
}

/// The dishes while they are being sorted — `SummaryLoading`'s skeleton rows, at the dish lines' own
/// height and gap so nothing moves when they print: the dish and the score as blank bars. The third
/// row has no score, as the board draws it: an unrated dish is an empty slot even before it has a
/// name.
private struct ReceiptSkeletonLines: View {
    var breathes: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Name widths, and whether a score bar follows — the board's proportions.
    private static let rows: [(name: CGFloat, scored: Bool)] = [(168, true), (96, true), (140, false)]

    var body: some View {
        VStack(spacing: AteMetrics.tight) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: AteMetrics.snug) {
                    ReceiptSkeletonBar(width: row.name, height: 14)
                    Spacer(minLength: 0)
                    if row.scored { ReceiptSkeletonBar(width: 34, height: 14) }
                }
                .frame(height: AteTextStyle.receiptLeadDish.lineBox(dynamicTypeSize))
            }
        }
        .padding(.top, AteMetrics.hairspace)
        .ateBreathing(breathes)
        .accessibilityHidden(true)
    }
}

/// `.sk` — `height:9px; border-radius:5px; background:rgba(36,20,31,.10)`.
private struct ReceiptSkeletonBar: View {
    let width: CGFloat
    var height: CGFloat = 9

    var body: some View {
        Capsule()
            .fill(AtePalette.slip.fg.opacity(0.10))
            .frame(width: width, height: height)
    }
}

/// `@keyframes breathe{50%{opacity:.45}}`, 1.6s ease-in-out, forever — gated on Reduce Motion. The
/// printing receipt's breath, and every kit skeleton's (``AteSkeleton``).
struct AteBreathing: ViewModifier {
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

extension View {
    /// Breathes this subtree down to 45% and back (``AteBreathing``) while `isOn`.
    func ateBreathing(_ isOn: Bool = true) -> some View {
        modifier(AteBreathing(isOn: isOn))
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
            ReceiptView(receipt: .preview)
            ReceiptView(receipt: .previewSingle)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
