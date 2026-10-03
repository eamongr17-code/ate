import SwiftUI

/// **The end of a finite page** — the Feed edition's `.end`: one muted line between two rules. No
/// button, no more loading.
struct AteEndRule: View {
    let line: String

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteEndRuleMetrics.gap) {
            rule
            Text(line)
                .ateText(.feedControl)
                .foregroundStyle(palette.muted)
                .fixedSize()
            rule
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteEndRuleMetrics.top)
        .padding(.bottom, AteEndRuleMetrics.bottom)
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle().fill(palette.hairline).frame(height: 1)
    }
}

enum AteEndRuleMetrics {
    /// `.end{gap:14px; padding:40px 20px 0}`, then 34 to the foot of the page.
    static let gap: CGFloat = 14
    static let top: CGFloat = 40
    static let bottom: CGFloat = 34
}
