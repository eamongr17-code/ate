import AteKit
import SwiftUI

/// **The bill** — what the entry page prints between its two dashed rules.
///
/// The receipt's line items at the page's own size (`.bill .li` is 14/1.75, where a receipt's is
/// 13/1.65) and **without the notes**: the words are already on the page above, so quoting them back
/// under each dish says the same thing twice. The notes stay on the share receipt, which travels
/// without them.
///
/// Every line is a correction: tapping one opens ``DishSheet`` (`entry_corrected`, `part=dish`). The
/// structure is Ate's guess and the person has the last word on all of it.
struct EntryBill: View {
    let items: [AteReceipt.Item]
    var onTap: ((AteReceipt.Item) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                line(item, number: index + 1)
            }
        }
        // `.contain` so the bill itself is a queryable element: its rows are already combined into
        // buttons, which would otherwise leave nothing addressable for a drive.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.bill")
    }

    @ViewBuilder
    private func line(_ item: AteReceipt.Item, number: Int) -> some View {
        let row = EntryBillRow(number: number, name: item.name, score: item.score)
        if let onTap {
            Button { onTap(item) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Change the dish")
        } else {
            row
        }
    }
}

/// One line: the number, the dish, a dot leader, and the score printed like a price (design rule 7 —
/// an unscored dish is an empty star and never a zero).
struct EntryBillRow: View {
    let number: Int
    let name: String
    var score: Rating?
    /// The skeleton draws the same row with nothing in it.
    var isBlank = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(String(format: "%02d", number))
                .ateText(.billLine)
                .foregroundStyle(AtePalette.paper.muted.opacity(isBlank ? 0.5 : 1))
            if isBlank == false {
                Text(name)
                    .ateText(.billLine)
                    .lineLimit(2)
                    // The leader is a greedy Canvas; without this it claims space from the name and a
                    // dish that fits on one line wraps anyway.
                    .layoutPriority(1)
            }
            AteDotLeader()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            if let score {
                Text(ScoreFormat.halfStep(score.value))
                    .ateText(.billScore)
                    .monospacedDigit()
                    .layoutPriority(1)
            } else {
                UnscoredMark(side: 14)
                    .foregroundStyle(AtePalette.paper.muted)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .opacity(isBlank ? 0.35 : 1)
            }
        }
        // `.li` is `line-height:1.75` — the row's box, not the glyphs'. A minimum, not a fixed height:
        // a dish name long enough to wrap grows its row, as a flex row does.
        .frame(minHeight: AteTextStyle.billLine.lineBox(dynamicTypeSize))
        .accessibilityElement(children: .combine)
    }
}

/// **The bill that has not printed yet**, and the one that could not.
///
/// `docs/DESIGN.md` does not draw these ("Not drawn — build with the existing vocabulary: offline /
/// not-yet-sorted entry, words show, the bill absent"), so they are built from the page's own pieces:
/// a mono label where a receipt would say what it is, blank bill rows the way paper waits in a
/// printer, and — only when there is something to do — one ink pill. No spinner, no apology.
struct EntryPendingBill: View {
    let state: EntryModel.State
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            Text(label)
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(1...3, id: \.self) { number in
                    EntryBillRow(number: number, name: "", isBlank: true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(state == .failed ? "The bill has not printed" : "The bill is printing")
            if state == .failed {
                AteButton(title: "Print it again", height: 52, action: onRetry)
                    .padding(.top, AteMetrics.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.pending")
    }

    /// The design's own words, in the design's own voice: paper says what it is.
    private var label: String {
        state == .failed ? "Not printed" : "Printing"
    }
}

#if DEBUG
#Preview("Bill") {
    ScrollView {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            EntryBill(items: AteReceipt.preview.items, onTap: { _ in })
            EntryPendingBill(state: .pending, onRetry: {})
            EntryPendingBill(state: .failed, onRetry: {})
        }
        .padding(AteMetrics.pagePaddingSide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atePaper()
        .background(AteColor.paper)
        .padding(AteMetrics.pageInset)
    }
    .ateGround()
}
#endif
