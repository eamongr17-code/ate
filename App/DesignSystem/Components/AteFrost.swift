import SwiftUI

/// **The frost behind the status bar** (round 5) — one, the same on every screen, so the clock and
/// the battery never sit on a slip or a photo scrolling under them. Before, only pushed pages had
/// anything there (the system navigation bar's edge effect), and tab roots had nothing.
///
/// A blur of whatever is under it, washed with the ground so it reads as linen (or ink) rather than
/// grey: an even band the status bar's height, with only a short soft foot (Eamon's pick, round 5).
extension View {
    /// Lays the status-bar frost over this screen's top edge. Hit-testing passes straight through.
    ///
    /// The status bar's depth is read from layout (this screen's own safe area), never from the
    /// window: asking UIKit for the window's insets while the shell's body is being built re-entered
    /// layout and tripped an AttributeGraph cycle that froze the shell.
    func ateStatusBarFrost() -> some View {
        modifier(AteStatusBarFrost())
    }
}

private struct AteStatusBarFrost: ViewModifier {
    @State private var depth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { depth = $0 }
            .overlay(alignment: .top) {
                AteFrost(depth: depth)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// The frost itself: an even band `depth` deep, feathered only at its foot. It stays inside the
/// status bar's strip — anything deeper frosted the pages' top bars and headers just under it.
struct AteFrost: View {
    let depth: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(AteFrostMetrics.wash))
        }
        .frame(height: depth)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1 - AteFrostMetrics.foot / max(depth, 1)),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

enum AteFrostMetrics {
    /// The band's soft foot.
    static let foot: CGFloat = 6
    /// The ground laid over the blur.
    static let wash: Double = 0.55
    /// The floating header's scrim: its feather below the header, and its wash.
    static let headerFeather: CGFloat = 32
    static let headerWash: Double = 0.6
    /// The floating header's arrival: the blur it comes into focus from, and the few points it
    /// settles down through.
    static let focusBlur: CGFloat = 14
    static let focusDrop: CGFloat = -10
}

/// **The floating header's backdrop** (round 5, Eamon's pick) — in place of the solid ground that
/// ended in a hard line across the list: a light frost the header's own height, from the top of the
/// screen, feathering out over 32 below it.
struct AteHeaderScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            frost
            frost
                .frame(height: AteFrostMetrics.headerFeather)
                .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
        }
        .padding(.bottom, -AteFrostMetrics.headerFeather)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frost: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(AteFrostMetrics.headerWash))
        }
    }
}

/// The floating header's arrival: out of a blur into focus, fading in, from a few points above —
/// scrim and all, so it comes back as a gradual overlay rather than a hard cut.
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
