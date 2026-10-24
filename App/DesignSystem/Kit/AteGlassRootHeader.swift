import SwiftUI

/// **The glass header** (`lighter-header.html` B, 22 Oct) — Journal, Feed and Saved. The root's
/// title row (title leading, the glass group trailing, a control apart before it), and under it an
/// accessory (the Journal's switch, the filter's chips), as one bar over the page: no ground of its
/// own, the page scrolling under it behind iOS 26's soft scroll edge (``SwiftUICore/View/ateHeaderEdge()``,
/// `header-rethink.html` A, 24 Oct). The header follows the finger: scrolling down it steps away up to
/// the status bar as fast as the page moves, scrolling up it comes back the same way, and it settles
/// all there or all away when the scroll stops. One title, always (Eamon, build 180).
///
/// The header is the page's top bar (`safeAreaBar`), never the navigation bar, and the room kept for
/// it never changes while it comes and goes: build 174 hid the native bar, and the inset leaving with
/// it moved the page under the finger and read as a scroll that brought the bar straight back. It
/// moves by its offset alone. All away, the edge leaves with it (a blurred strip with nothing in it
/// would only hide the page) and the page's own colour sits behind the clock.
private struct AteGlassRootHeader<Apart: View, Controls: View, Accessory: View>: ViewModifier {
    let title: AteRootHeaderTitle
    let subtitle: String?
    /// How far it has stepped away: 0 all there, 1 all away.
    let hidden: CGFloat
    let showsApart: Bool
    let apart: Apart
    let controls: Controls
    let accessory: Accessory

    /// The header's height, title row and accessory: the room the page keeps under it.
    @State private var height: CGFloat = AteMetrics.hit

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .ateHeaderEdge()
            .scrollEdgeEffectHidden(isAway, for: .top)
            .overlay(alignment: .top) {
                if isAway { AteClockGround() }
            }
            .environment(\.ateGlassHeaderTravel, travel)
    }

    /// How far the header moves from all there to all away: its height, and past the status bar.
    private var travel: CGFloat { height + AteGlassRootHeaderMetrics.clearance }

    private var isAway: Bool { hidden >= 1 }

    // MARK: - The header

    private var header: some View {
        VStack(spacing: 0) {
            titleRow
            accessory
        }
        // The header's own foot, so the first slip never sits tight under the title (build 181).
        .padding(.bottom, AteGlassRootHeaderMetrics.foot)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // Up past the status bar, as far as the page has taken it; the page under it never moves.
        .offset(y: -hidden * travel)
        .opacity(1 - hidden)
        .allowsHitTesting(hidden < 0.5)
        .accessibilityHidden(isAway)
    }

    private var titleRow: some View {
        HStack(spacing: AteMetrics.snug) {
            AteRootTitle(title: title, subtitle: subtitle)
                .accessibilityIdentifier("root.title")
                .fixedSize()
            Spacer(minLength: 0)
            if showsApart {
                apart
                    .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            AteGlassGroup { controls }
        }
        .padding(.leading, title == .wordmark ? AteRootHeaderMetrics.wordmarkLeading : AteMetrics.gutter)
        .padding(.trailing, AteRootHeaderMetrics.trailing)
        .frame(height: AteMetrics.hit)
    }
}

/// ``SwiftUICore/View/ateRootBarHiding(_:)``. Only a finger's scroll moves the header — a drag or
/// its coast — point for point with the page, so a slow scroll brings it back slowly and a flick
/// fast; when the scroll stops it settles the nearer way.
private struct AteRootBarHiding: ViewModifier {
    @Binding var hidden: CGFloat
    @State private var phase: ScrollPhase = .idle
    /// How far under the header the page last was.
    @State private var depth: CGFloat = 0
    @Environment(\.ateGlassHeaderTravel) private var travel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Reading: Equatable {
        var offset: CGFloat
        /// How far under the header the page has gone: zero at rest.
        var depth: CGFloat
        /// Past the end — the bottom's rubber band, which must not bring the header back.
        var isPastEnd: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, now in
                phase = now
                if now == .idle { settle() }
            }
            .onScrollGeometryChange(for: Reading.self) { geometry in
                let end = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
                return Reading(
                    offset: geometry.contentOffset.y,
                    depth: geometry.contentOffset.y + geometry.contentInsets.top,
                    isPastEnd: geometry.contentOffset.y > end
                )
            } action: { old, new in
                depth = new.depth
                var next = hidden
                let isFinger = phase == .interacting || phase == .decelerating
                if isFinger, new.isPastEnd == false, old.isPastEnd == false {
                    next += (new.offset - old.offset) / travel
                }
                // Never further away than the page has gone under it: at the top it is all there.
                next = min(max(next, 0), 1, max(new.depth, 0) / travel)
                if next != hidden { hidden = next }
            }
    }

    /// Half way or more, and with room for it, all away; otherwise all there.
    private func settle() {
        guard hidden > 0, hidden < 1 else { return }
        let away = hidden >= 0.5 && depth >= travel
        withAnimation(reduceMotion ? nil : AteGlassRootHeaderMetrics.slide) { hidden = away ? 1 : 0 }
    }
}

extension EnvironmentValues {
    /// How far a glass header moves from all there to all away, for its page's
    /// ``SwiftUICore/View/ateRootBarHiding(_:)``.
    @Entry var ateGlassHeaderTravel: CGFloat = 160
}

enum AteGlassRootHeaderMetrics {
    /// The room under the header's last row, title or accessory, before the page starts.
    static let foot: CGFloat = AteMetrics.snug
    /// How far past the header's own height it travels to clear the status bar.
    static let clearance: CGFloat = 80
    /// The header settling all there or all away once a scroll stops.
    static let slide: Animation = .smooth(duration: 0.24)
    /// The page's colour behind the clock while the header is away eases out over this much.
    static let clockFade: CGFloat = 12
}

/// **The ground behind the clock** while a glass header is all away: the page's own colour over the
/// status bar, easing out just below it, so the time never sits on a slip. Its colour is the page's,
/// so it can never read as a band.
private struct AteClockGround: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let solid = proxy.safeAreaInsets.top
            let fade = AteGlassRootHeaderMetrics.clockFade
            LinearGradient(
                stops: [
                    .init(color: palette.ground, location: 0),
                    .init(color: palette.ground, location: solid / (solid + fade)),
                    .init(color: palette.ground.opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: solid + fade)
            .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Installs a tab root's **glass header** (``AteGlassRootHeader``) in place of the native bar:
    /// the same title and glass group as ``ateRootToolbar(title:subtitle:inline:isCollapsed:controls:)``
    /// (never an inline title), with an `accessory` under the row, the whole of it `hidden` of the way
    /// away (0 to 1).
    func ateGlassRootHeader<Apart: View, Controls: View, Accessory: View>(
        title: AteRootHeaderTitle,
        subtitle: String? = nil,
        hidden: CGFloat,
        showsApart: Bool = false,
        @ViewBuilder apart: () -> Apart = { EmptyView() },
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        modifier(AteGlassRootHeader(
            title: title, subtitle: subtitle, hidden: hidden,
            showsApart: showsApart, apart: apart(), controls: controls(), accessory: accessory()
        ))
    }

    /// Moves a glass header away as the page scrolls down and back as it scrolls up, with the finger,
    /// and all there near the top — Safari's bar. Apply to the root's own `ScrollView` or `List`.
    func ateRootBarHiding(_ hidden: Binding<CGFloat>) -> some View {
        modifier(AteRootBarHiding(hidden: hidden))
    }
}
