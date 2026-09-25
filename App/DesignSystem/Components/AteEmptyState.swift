import SwiftUI

/// **An empty state** — `MainEmpty`'s shape, generalised: one big line on the ground, and at most
/// one ink pill under it.
///
/// No receipt motif (`docs/DESIGN.md`): nothing has been printed yet, so there is no paper, no torn
/// edge, no mono order number and no dashed rule. Never a `ContentUnavailableView`, never an
/// icon-and-explanation, never helper copy (design rule 1) — the line is the whole state.
struct AteEmptyState: View {
    /// One line, in the app's voice. Newlines are the design's own line breaks and are honoured.
    let title: String
    /// A developer-facing detail, for the one screen that exists to explain a broken checkout. No
    /// product surface passes it.
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    /// `gap:24px` between the line and its pill.
    private static let gap: CGFloat = 24
    /// `MainEmpty`'s button: `height:52px; padding:0 28px`.
    private static let buttonHeight: CGFloat = 52
    private static let buttonPadding: CGFloat = 28

    var body: some View {
        VStack(spacing: Self.gap) {
            AteTitle(text: title, style: .screenTitle)
            if let detail {
                Text(detail)
                    .ateText(.meta)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                AteButton(
                    title: actionTitle,
                    height: Self.buttonHeight,
                    hugPadding: Self.buttonPadding,
                    action: action
                )
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Empty states") {
    VStack(spacing: 80) {
        AteEmptyState(title: "Nothing\non the tab.", actionTitle: "Write your first", action: {})
        AteEmptyState(title: "Nothing saved\nyet.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ateGround()
}
#endif
