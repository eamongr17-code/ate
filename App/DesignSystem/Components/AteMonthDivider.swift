import SwiftUI

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
