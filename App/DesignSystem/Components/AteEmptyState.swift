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

/// **Where an empty state sits — one rule, every screen** (round 3).
///
/// `MainEmpty` centres its state between the segment's foot + 22 and 110 above the bottom of the
/// screen: on the 844 artboard, the band from 186 to 734, centred on 460. Every other empty state —
/// Saved, the Feed, Search, the entry page's failures — is centred on **that same line**, whatever
/// sits above it, so switching tabs never makes the line jump. The frame is only as tall as it must
/// be to put its centre there.
enum AteEmptyPlacement {
    /// The band's top on the artboard: 60 content top + 44 header + 16 + the 44 segment + 22.
    static let bandTop: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.loose
        + AteMetrics.segmentHeight + 2 * AteMetrics.tight + 22
    /// …and its clearance above the bottom of the screen.
    static let bandBottom: CGFloat = 110

    /// The screen line every empty state is centred on.
    @MainActor
    static var centreLine: CGFloat {
        (bandTop + AteScreen.height - bandBottom) / 2
    }

    /// How tall a centred frame starting `top` points down the screen must be.
    @MainActor
    static func height(below top: CGFloat) -> CGFloat {
        max(0, 2 * (centreLine - top))
    }
}

extension View {
    /// Centres this empty state on ``AteEmptyPlacement/centreLine``. `top` is where this view begins,
    /// measured from the top of the screen (not the safe area) — the artboards' own coordinates.
    func ateEmptyPlacement(top: CGFloat) -> some View {
        modifier(AteEmptyPlacementModifier(top: top))
    }
}

private struct AteEmptyPlacementModifier: ViewModifier {
    let top: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: AteEmptyPlacement.height(below: top))
    }
}

/// **"Couldn't reach Ate."** — the one failure a list or a page shows when the phone or the server
/// let it down: the line, and a retry. Distinct from a thing that is *gone* (``LoadFailure``), which
/// gets no retry because none would work.
struct AteUnreachableState: View {
    let retry: () -> Void

    var body: some View {
        AteEmptyState(title: "Couldn't\nreach Ate.", actionTitle: "Try again", action: retry)
            .accessibilityIdentifier("state.unreachable")
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
