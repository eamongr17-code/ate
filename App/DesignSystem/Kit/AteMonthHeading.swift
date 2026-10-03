import SwiftUI

/// **A month's name between slips** — the Journal's divider (`.mdiv`): the month alone, Bricolage
/// 800 at 22, scrolling with the list (it never pins). The year joins it, muted, only when it is not
/// this year's. No count: the inline title already says where you are.
struct AteMonthHeading: View {
    let month: String
    /// `nil` in the current year.
    var year: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(month)
                .ateText(.kitMonthHeading)
                .foregroundStyle(palette.fg)
                .lineLimit(1)
            if let year {
                Text(year)
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMonthHeadingMetrics.side)
        .padding(.top, AteMonthHeadingMetrics.top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum AteMonthHeadingMetrics {
    /// `.mdiv{padding:14px 4px 0}`, in from the card's edge.
    static let top: CGFloat = 14
    static let side: CGFloat = AteMetrics.listGutter + AteMetrics.tight
}

extension AteTextStyle {
    /// `.mdiv`: Bricolage 800 at 22, `letter-spacing:-.025em`, `line-height:1`.
    static let kitMonthHeading = AteTextStyle(
        voice: .display, size: 22, weight: 800, trackingEm: -0.025, lineHeight: 1.0, textStyle: .title2
    )
}
