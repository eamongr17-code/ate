import SwiftUI

/// **A month divider** (round 7, `Main` / `JournalScrolled`) — the month's name, large, and beside it
/// on the same baseline the year and the month's count, muted, set apart by space rather than a dot
/// (DESIGN.md rule 2; no mono outside receipts): "September  2026   14 entries". No rule, no
/// container: it stands on the ground over the month's first slip.
struct AteMonthDivider: View {
    let title: String
    let year: String
    let count: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMonthDividerMetrics.gap) {
            Text(title)
                .ateTextLine(.monthTitle)
                .foregroundStyle(AtePalette.automatic.fg)
                .lineLimit(1)
                .layoutPriority(1)
            AteMetaParts(parts: [year] + (count.map { [$0] } ?? []))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.top, AteMonthDividerMetrics.top)
        .padding(.bottom, AteMonthDividerMetrics.bottom)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// **Muted meta, spaced apart** — a divider's year and count, a calendar's visits and stars. The
/// design's answer to "two values, no dot": each part its own word group, a clear space between.
struct AteMetaParts: View {
    let parts: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMonthDividerMetrics.partGap) {
            ForEach(parts, id: \.self) { part in
                Text(part)
                    .ateText(.meta)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(AtePalette.automatic.muted)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

enum AteMonthDividerMetrics {
    /// Between the meta's parts: a wide word space, where a dot would have been.
    static let partGap: CGFloat = 14
    /// `padding: 22px 20px 10px; gap: 10px`.
    static let top: CGFloat = 22
    static let bottom: CGFloat = 10
    static let gap: CGFloat = 10
}
