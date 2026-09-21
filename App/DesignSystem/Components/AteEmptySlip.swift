import SwiftUI

/// **A slip that *is* the state** — `MainEmpty`'s shape, generalised.
///
/// The design answers "nothing here yet" by printing a receipt that says so: a mono label where the
/// order number goes, one big line, at most one line of the app's own voice, a dashed rule, and at
/// most one ink pill. Never a `ContentUnavailableView`, never an icon-and-explanation, never helper
/// copy (design rule 1) — the words on the paper are the whole state.
struct AteEmptySlip: View {
    /// The mono label at the top: `Order #0001` on an empty journal, the surface's own name elsewhere.
    var label: String?
    /// One line, in the app's voice. Newlines are the design's own line breaks and are honoured.
    let title: String
    /// At most one line under it. Optional because most states need nothing more.
    var prose: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AteMetrics.loose) {
            if let label {
                Text(label)
                    .ateText(.receiptLabel)
                    .foregroundStyle(AtePalette.paper.muted)
            }
            Text(title)
                .ateText(.emptyTitle)
                .multilineTextAlignment(.center)
            if let prose {
                Text(prose)
                    .ateText(.proseLarge)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                AteDashedRule()
                AteButton(title: actionTitle, height: 52, action: action)
            }
        }
        .padding(.top, 34)
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.bottom, 22 + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
        // The design insets it from the gutter: an empty slip is a smaller piece of paper than a
        // full one, which is what makes it read as a state rather than as a first entry.
        .padding(.horizontal, 22)
    }
}

#if DEBUG
#Preview("Empty slips") {
    ScrollView {
        VStack(spacing: AteMetrics.section) {
            AteEmptySlip(
                label: "Order #0001",
                title: "Nothing\non the tab.",
                prose: "Eat something good,\nthen tell us about it.",
                actionTitle: "Write your first",
                action: {}
            )
            AteEmptySlip(label: "Saved", title: "Nothing saved\nyet.")
        }
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
