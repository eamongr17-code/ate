import AteKit
import SwiftUI

/// **The monthly statement** — `Recap.dc.html`'s paper.
///
/// A receipt, and legitimately one under design rule 4: a month of entries was totalled and printed.
/// Same paper, same mono, same dashed rules, dot leaders, barcode and torn edge as the entry's
/// receipt — the bands are simply the month's figures rather than a visit's dishes.
///
/// Bands that have nothing behind them are **absent, not empty**: a month where nothing was scored
/// has no "Top of the month", and printing the heading over a blank would be printing something that
/// was never printed.
struct StatementReceiptView: View {
    let statement: MonthlyStatement
    /// Who the statement is for — a receipt is signed, or it is a receipt from nobody. The
    /// statement carries its own handle; this is only the fallback for a payload that predates it.
    var handle: String = ""

    private var signature: String { statement.username ?? handle }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: StatementReceiptView.bandGap) {
            header
            AteDashedRule()
            totals
            if statement.topDishes.isEmpty == false {
                AteDashedRule()
                Text("Top of the month")
                    .ateText(.receiptLabel)
                    .foregroundStyle(AtePalette.paper.fg)
                top
            }
            if habits.isEmpty == false {
                AteDashedRule()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(habits, id: \.label) { habit in
                        line(habit.label, value: habit.value)
                    }
                }
            }
            AteBarcode()
                .padding(.top, AteMetrics.tight)
            Text("Ate that.")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
                .frame(maxWidth: .infinity)
        }
        // `padding:22px 18px 16px` — and the torn edge under it.
        .padding(.top, 22)
        .padding(.horizontal, 18)
        .padding(.bottom, AteMetrics.loose + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }

    /// `gap:11px` between the statement's bands.
    private static let bandGap: CGFloat = 11

    // MARK: - Bands

    private var header: some View {
        VStack(spacing: AteMetrics.tight) {
            Text("Statement")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
            // 40pt at `.h`'s line-height of 1 — the same size a screen names itself at, because on
            // a statement the month IS the title. A `Text` cannot set a line box tighter than its
            // font, which is what ``AteExactText`` is for.
            AteExactText(text: statement.month.title, style: .screenTitle, colour: AtePalette.paper.fg)
            Text(verbatim: "@\(signature)")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statement.month.title) statement, @\(signature)")
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("Orders", value: statement.orders.formatted())
            line("Places", value: statement.places.formatted())
            line("New to you", value: statement.newPlaces.formatted())
            line("Dishes", value: statement.dishes.formatted())
            line("Stars handed out", value: ScoreFormat.average(statement.stars))
            // An unscored month prints the em-dash, never `0.0` (data-model §1.3).
            line("Average", value: ScoreFormat.average(statement.average))
        }
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(statement.topDishes.enumerated()), id: \.element.id) { index, dish in
                line(
                    name(dish),
                    value: dish.score.map(ScoreFormat.halfStep) ?? ScoreFormat.unratedPlaceholder,
                    number: index + 1
                )
            }
        }
    }

    /// "Tagliatelle al ragù, Tipo 00" — the dish, then where it was. A comma, not a dot separator
    /// (design rule 2).
    private func name(_ dish: MonthlyStatement.TopDish) -> String {
        guard let place = dish.restaurantName, place.isEmpty == false else { return dish.dishName }
        return "\(dish.dishName), \(place)"
    }

    /// "Most ordered … Pasta x4" / "Regular at … Tipo 00 x2". Both optional; a month with one visit
    /// has no habit to report.
    private var habits: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let ordered = statement.mostOrdered {
            rows.append(("Most ordered", "\(ordered.dishName) x\(ordered.count)"))
        }
        if let visited = statement.mostVisited {
            rows.append(("Regular at", "\(visited.restaurantName) x\(visited.count)"))
        }
        return rows
    }

    // MARK: - A line

    /// A statement line: an optional `01`, the label, dot leaders, and the figure on the right —
    /// scores print like prices (design rule 7).
    private func line(_ label: String, value: String, number: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            if let number {
                Text(String(format: "%02d", number))
                    .ateText(.receiptLine)
                    // **Never wraps.** Without this an unbounded label next to it takes the whole
                    // row and the ordinal is squeezed to one glyph wide: "0" on one line and "1"
                    // on the next, which is how "01 Tagliatelle al ragù, Tipo 00" printed.
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(AtePalette.paper.muted)
            }
            Text(label)
                .ateText(.receiptLine)
                // Two lines, as a receipt's line item takes — a "dish, restaurant" string is long
                // and it is the thing that is allowed to wrap.
                .lineLimit(2)
                // The leader is a greedy Canvas; without this it claims space from the label.
                .layoutPriority(1)
            AteDotLeader()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(value)
                .ateText(.receiptScore)
                .monospacedDigit()
                .layoutPriority(1)
        }
        .frame(minHeight: AteTextStyle.receiptLine.lineBox(dynamicTypeSize), alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Statement") {
    ScrollView {
        StatementReceiptView(
            statement: InMemoryStatsService.seededStatements[0],
            handle: "eamon"
        )
        .padding(.horizontal, 34)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
