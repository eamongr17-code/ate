import SwiftUI

/// **The statement**: a whole slip — 16pt corners all round, no torn edge — carrying three totals,
/// parted by dashed rules.
///
/// The same object on `You` and on somebody else's profile — the record, counted. Torn edges belong
/// to dish entry slips alone (`docs/DESIGN.md`), so this one is `.slip.whole`. Its labels keep the
/// mono caps, because a total is still a printed figure.
struct AteStatsSlip: View {
    /// Value first, label under it. Three of them, the way both artboards draw it.
    let cells: [(value: String, label: String)]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    // `border-left:1.5px dashed rgba(36,20,31,.3)` down the whole column: a 28pt
                    // figure, the 4 gap, and an 11pt label's 1.35 line.
                    AteDashedLine(opacity: 0.3, axis: .vertical).frame(height: Self.columnHeight)
                }
                VStack(spacing: AteMetrics.tight) {
                    Text(cell.value)
                        .ateTextExact(.statValue)
                        .offset(y: -AteFont.exactBaselineDrop(for: .statValue, dynamicTypeSize: dynamicTypeSize))
                    Text(cell.label)
                        .ateTextExact(.receiptLabel)
                        .foregroundStyle(AtePalette.slip.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        // `padding:14px 8px`, and no tear.
        .padding(.vertical, 14)
        .padding(.horizontal, AteMetrics.snug)
        .frame(maxWidth: .infinity)
        .ateSlip()
        .background(AteColor.slip, in: RoundedRectangle(cornerRadius: AteMetrics.slipCorner, style: .continuous))
    }

    private static let columnHeight: CGFloat = AteTextStyle.statValue.lineBox(.large) + AteMetrics.tight
        + AteTextStyle.receiptLabel.lineBox(.large)
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
