import AteKit
import SwiftUI

/// **The receipt that has not printed yet**, and the one that could not.
///
/// `docs/DESIGN.md` does not draw these ("Not drawn — build with the existing vocabulary: offline /
/// not-yet-sorted entry, words show, receipt absent"), so they are built from the pieces that do
/// exist: a piece of paper, a mono label where the order number goes, the dashed rule, and — only
/// when there is something to do — one ink pill. No spinner, no explanation, no apology.
///
/// The pending state is the receipt's own skeleton: the bands are there, drawn as dashed rules, the
/// way blank paper waits in a printer.
struct EntryPendingSlip: View {
    let state: EntryModel.State
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: AteMetrics.regular) {
            Text(label)
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
            AteDashedRule()
            skeletonLines
            AteDashedRule()
            if state == .failed {
                AteButton(title: "Print it again", height: 52, action: onRetry)
                    .padding(.top, AteMetrics.tight)
            }
        }
        .padding(.top, 22 + 16)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + 2 + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }

    /// The design's own words, in the design's own voice: a receipt says what it is.
    private var label: String {
        state == .failed ? "Not printed" : "Printing"
    }

    /// Three blank line-item rows: a number column, a dotted leader where the dish will be, and the
    /// space the score will take. The skeleton of the real component, never a grey bar.
    private var skeletonLines: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            ForEach(0..<3, id: \.self) { index in
                HStack(alignment: .center, spacing: AteMetrics.snug) {
                    Text(String(format: "%02d", index + 1))
                        .ateText(.receiptLine)
                        .foregroundStyle(AtePalette.paper.muted.opacity(0.5))
                    AteDotLeader()
                    UnscoredMark(side: 14)
                        .opacity(0.35)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state == .failed ? "Receipt not printed" : "Receipt printing")
    }
}

#if DEBUG
#Preview("Pending and failed") {
    ScrollView {
        VStack(spacing: AteMetrics.section) {
            EntryPendingSlip(state: .pending, onRetry: {})
            EntryPendingSlip(state: .failed, onRetry: {})
        }
        .padding(.horizontal, 22)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
