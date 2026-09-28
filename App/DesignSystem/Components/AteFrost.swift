import SwiftUI

/// **The top frost** (round 7, `JournalScrolled`) — ONE continuous frost from the screen's top edge
/// down through whatever chrome sits there — the status bar alone, a tab's compact header, a pushed
/// page's top bar — fading out softly at its foot. No separate status-bar band, and no hard edge
/// anywhere: one blur, washed with the ground so it reads as linen (or ink), never grey, and masked
/// to nothing over its last ``AteFrostMetrics/feather`` points.
///
/// At rest — a page at its top — it is not there at all: the header sits straight on the ground. It
/// comes in over the first few points of scroll, as the page starts to pass under it.
///
/// Laid by the chrome that owns the top of each screen (``AteTabRootHeader``'s layers on a tab root,
/// ``AteNavigationBarModifier`` on a pushed page) *under* its controls, never over them.
struct AteTopFrost: View {
    /// How far down it is solid, from the top of the screen.
    let depth: CGFloat
    /// 0…1: how much of it shows (``AteFrostMetrics/presence(offset:)``).
    let presence: Double

    var body: some View {
        // At rest there is nothing here at all — not a clear blur over the header, which UIKit would
        // still count as covering the controls under it.
        if presence > 0 {
            frost
        }
    }

    private var frost: some View {
        let height = depth + AteFrostMetrics.feather
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(AteFrostMetrics.wash))
        }
        .frame(height: height)
        .mask {
            // `mask-image: linear-gradient(to bottom, #000 70%, transparent)` — solid, then a linear
            // fade to nothing.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: depth / max(height, 1)),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(presence)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AteFrostMetrics {
    /// The soft foot: `JournalScrolled`'s 150pt frost fades over its last 30% — 45 points.
    static let feather: CGFloat = 45
    /// `background: rgba(239,234,226,.82)` — the ground laid over the blur.
    static let wash: Double = 0.82
    /// How far the page moves before the frost is whole. Over the first few points it fades in, so a
    /// page leaving its resting top is not met by a band snapping on.
    static let arrival: CGFloat = 12
    /// The solid part runs 7 below the chrome's controls (`JournalScrolled`: the 44pt row ends at 98,
    /// the frost is solid to 105).
    static let belowControls: CGFloat = 7

    /// The status bar alone — a tab root scrolled with its header down.
    static var statusDepth: CGFloat { AteScreen.safeArea.top }
    /// Through a tab root's compact header: its 44pt controls sit centred in its 52pt row.
    static var headerDepth: CGFloat {
        AteScreen.safeArea.top + AteCompactHeaderMetrics.row
            - (AteCompactHeaderMetrics.row - AteMetrics.hit) / 2 + belowControls
    }
    /// Through a pushed page's top bar: its 44pt glass controls sit at the top of the bar.
    static var barDepth: CGFloat { AteScreen.safeArea.top + AteMetrics.hit + belowControls }

    /// How much of the frost shows at a scroll offset: none at rest, whole past ``arrival``.
    static func presence(offset: CGFloat) -> Double {
        Double(min(max(offset / arrival, 0), 1))
    }

    /// The floating header's arrival: the blur it comes into focus from, and the few points it
    /// settles down through.
    static let focusBlur: CGFloat = 14
    static let focusDrop: CGFloat = -10
}

/// The floating header's arrival: out of a blur into focus, fading in, from a few points above —
/// so it comes back as a gradual overlay rather than a hard cut.
struct AteHeaderFocus: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * AteFrostMetrics.focusBlur)
            .opacity(progress)
            .offset(y: (1 - progress) * AteFrostMetrics.focusDrop)
    }
}

extension AnyTransition {
    /// The floating header's arrival and departure.
    static var ateHeaderReturn: AnyTransition {
        .modifier(active: AteHeaderFocus(progress: 0), identity: AteHeaderFocus(progress: 1))
    }
}
