import SwiftUI

/// **The statement**: a short piece of receipt paper carrying three totals, parted by dashed rules.
///
/// The same object on `You` and on somebody else's profile — the record, counted. Its labels are the
/// receipt's own mono caps, because a total on paper is a printed thing.
struct AteStatsSlip: View {
    /// Value first, label under it. Three of them, the way both artboards draw it.
    let cells: [(value: String, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    AteDashedLine(axis: .vertical).frame(height: 44)
                }
                VStack(spacing: AteMetrics.tight) {
                    Text(cell.value).ateText(.statValue)
                    Text(cell.label)
                        .ateText(.receiptLabel)
                        .foregroundStyle(AtePalette.paper.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        // `padding:14px 8px` — and the torn edge under it.
        .padding(.vertical, 14)
        .padding(.horizontal, AteMetrics.snug)
        .padding(.bottom, AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }
}

#if DEBUG
#Preview("Stats") {
    VStack(spacing: AteMetrics.section) {
        AteStatsSlip(cells: [("86", "Orders"), ("40", "Places"), ("201", "Dishes")])
        AteStatsSlip(cells: [("0", "Orders"), ("0", "Places"), ("0", "Dishes")])
    }
    .padding(AteMetrics.gutter)
    .frame(maxHeight: .infinity, alignment: .top)
    .ateGround()
}
#endif
