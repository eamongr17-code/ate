import SwiftUI

/// **A month divider** (round 7, `Main` / `JournalScrolled`) — the month's name, large, and beside it
/// on the same baseline the year and the month's count in the muted mono: "September 2026 · 14
/// ENTRIES". No rule, no container: it stands on the ground over the month's first slip.
struct AteMonthDivider: View {
    let title: String
    let meta: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMonthDividerMetrics.gap) {
            Text(title)
                .ateTextLine(.monthTitle)
                .foregroundStyle(AtePalette.automatic.fg)
                .lineLimit(1)
                .layoutPriority(1)
            Text(meta)
                .ateText(.monthMeta)
                .foregroundStyle(AtePalette.automatic.muted)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.top, AteMonthDividerMetrics.top)
        .padding(.bottom, AteMonthDividerMetrics.bottom)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum AteMonthDividerMetrics {
    /// `padding: 22px 20px 10px; gap: 10px`.
    static let top: CGFloat = 22
    static let bottom: CGFloat = 10
    static let gap: CGFloat = 10
}
