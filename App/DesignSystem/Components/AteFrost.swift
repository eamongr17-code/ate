import SwiftUI

/// **The frost behind the status bar** (round 5) — one, the same on every screen, so the clock and
/// the battery never sit on a slip or a photo scrolling under them. Before, only pushed pages had
/// anything there (the system navigation bar's edge effect), and tab roots had nothing.
///
/// A blur of whatever is under it, washed with the ground so it reads as linen (or ink) rather than
/// grey. `-ate-r5-frost`: A a gradient frost, full behind the clock and easing out through the
/// strip; B an even band, the status bar's height, with only a short feather at its foot.
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
                AteFrost(edge: .top, depth: depth, variant: AteChromeVariant.frost)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// The frost itself: a band `depth` deep.
struct AteFrost: View {
    let edge: VerticalEdge
    let depth: CGFloat
    var variant: AteChromeVariant = .a

    /// It stays inside the status bar's own strip: anything deeper frosted the pages' top bars and
    /// headers, which sit just under it.
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(AteFrostMetrics.wash))
        }
        .frame(height: depth)
        .mask {
            LinearGradient(stops: stops, startPoint: start, endPoint: end)
        }
    }

    private var start: UnitPoint { edge == .top ? .top : .bottom }
    private var end: UnitPoint { edge == .top ? .bottom : .top }

    private var stops: [Gradient.Stop] {
        switch variant {
        case .a:
            // Full behind the clock, easing out through the lower part of the strip — no line.
            return [
                .init(color: .black, location: 0),
                .init(color: .black, location: AteFrostMetrics.gradientSolid),
                .init(color: .black.opacity(0.5), location: (AteFrostMetrics.gradientSolid + 1) / 2),
                .init(color: .clear, location: 1),
            ]
        case .b:
            // Even to the strip's foot, with only a short feather there.
            let foot = 1 - AteFrostMetrics.bandFeather / max(depth, 1)
            return [
                .init(color: .black, location: 0),
                .init(color: .black, location: foot),
                .init(color: .clear, location: 1),
            ]
        }
    }
}

enum AteFrostMetrics {
    /// A: how much of the strip is full frost before it eases out.
    static let gradientSolid: CGFloat = 0.55
    /// B: the band's soft foot.
    static let bandFeather: CGFloat = 6
    /// The ground laid over the blur.
    static let wash: Double = 0.55
}

/// **The floating header's backdrop** (round 5) — in place of the solid ground that ended in a
/// hard line across the list. A frost the header's own height, from the top of the screen, that
/// feathers out below it (`-ate-r5-header`: A a lighter frost with a long feather, B a denser
/// scrim with a short one).
struct AteHeaderScrim: View {
    var variant: AteChromeVariant = .a

    var body: some View {
        let feather = variant == .a ? AteFrostMetrics.headerFeatherA : AteFrostMetrics.headerFeatherB
        VStack(spacing: 0) {
            frost
            frost
                .frame(height: feather)
                .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
        }
        .padding(.bottom, -feather)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frost: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(
                variant == .a ? AteFrostMetrics.headerWashA : AteFrostMetrics.headerWashB
            ))
        }
    }
}

extension AteFrostMetrics {
    static let headerFeatherA: CGFloat = 32
    static let headerFeatherB: CGFloat = 14
    static let headerWashA: Double = 0.6
    static let headerWashB: Double = 0.85
}

/// Variant A's arrival: out of a blur into focus, fading in, from a few points above.
struct AteHeaderFocus: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * AteFrostMetrics.focusBlur)
            .opacity(progress)
            .offset(y: (1 - progress) * AteFrostMetrics.focusDrop)
    }
}

extension AteFrostMetrics {
    static let focusBlur: CGFloat = 14
    /// More than any status bar is deep: how far past the top edge B's header travels to be gone.
    static let statusBarAllowance: CGFloat = 80
    static let focusDrop: CGFloat = -10
}

extension AnyTransition {
    /// The floating header's arrival and departure, per `-ate-r5-header`.
    @MainActor
    static var ateHeaderReturn: AnyTransition {
        switch AteChromeVariant.header {
        case .a:
            .modifier(active: AteHeaderFocus(progress: 0), identity: AteHeaderFocus(progress: 1))
        case .b:
            // Past the status bar too, which the scrim reaches up under.
            .move(edge: .top).combined(with: .offset(y: -AteFrostMetrics.statusBarAllowance))
        }
    }
}
