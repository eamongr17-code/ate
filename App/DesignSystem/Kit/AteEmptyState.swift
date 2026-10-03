import SwiftUI

/// **The empty state** — one anatomy app-wide: one line in Bricolage 800 at 40, centred between the
/// header and the tab bar, and at most one ink pill 22 below it. No receipt motif, no illustration,
/// no second line, no helper copy. The line's own breaks are the design's and are honoured.
///
/// It fills the space it is given and centres itself in it; the screen gives it the band between its
/// header and the tab bar.
struct AteEmptyState: View {
    let line: String
    var pill: (title: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: AteEmptyStateMetrics.gap) {
            AteTitle(text: line, style: .screenTitle)
            if let pill {
                AteInkPill(title: pill.title, size: .empty, action: pill.action)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum AteEmptyStateMetrics {
    /// `gap:22px` between the line and its pill.
    static let gap: CGFloat = 22
}
