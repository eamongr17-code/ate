import SwiftUI

/// **The glass header** (`lighter-header.html` B, 22 Oct) — Journal, Feed and Saved. The root's
/// title row (title leading, the glass group trailing, a control apart before it), and under it an
/// accessory (the Journal's switch, the filter's chips), as one header over the page: no ground, the
/// page scrolling under it behind a frost of its own ground once it is under it. The header follows
/// the finger: scrolling down it steps away up to the status bar as fast as the page moves, scrolling
/// up it comes back the same way, and it settles all there or all away when the scroll stops. One
/// title, always: the header no longer folds its title inline (Eamon, build 180).
///
/// The header is drawn over the page, never in the navigation bar, and the room kept for it never
/// changes while it comes and goes: build 174 hid the native bar, and the inset leaving with it
/// moved the page under the finger and read as a scroll that brought the bar straight back.
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
    @State private var isOverPage = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: height)
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > AteHeaderGroundMetrics.showAfter
            } action: { _, isUnder in
                withAnimation(.easeOut(duration: AteHeaderGroundMetrics.switchDuration)) { isOverPage = isUnder }
            }
            .overlay(alignment: .top) { frost }
            .overlay(alignment: .top) { header }
            .environment(\.ateGlassHeaderTravel, travel)
    }

    /// How far the header moves from all there to all away: its height, and past the status bar.
    private var travel: CGFloat { height + AteGlassRootHeaderMetrics.clearance }

    private var isAway: Bool { hidden >= 1 }

    // MARK: - The frost

    /// The page's own ground from the screen's top edge to the header's bottom, easing out over the
    /// page past it, following the header as it moves; the status bar's height alone while it is
    /// away. A blur under the ground shows the page faintly through it, but the colour is the
    /// ground's, never the material's own grey (build 177: a lighter band with an edge, in dark mode
    /// most of all). Off at rest (build 92: at rest the page is one surface).
    private var frost: some View {
        GeometryReader { proxy in
            AteHeaderFrost(solid: proxy.safeAreaInsets.top + max(0, height - hidden * travel))
        }
        .opacity(isOverPage ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

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
    /// The frost runs this far past the header's bottom, fading out, so the page meets it softly.
    static let fade: CGFloat = 31
    /// The room under the header's last row, title or accessory, before the page starts.
    static let foot: CGFloat = AteMetrics.snug
    /// The ground over the blur: the page's own colour, with the page moving under it plainly
    /// through it (Eamon, build 180: a little glass, not a new colour; 24 Oct: more glass, 0.82 → 0.6;
    /// build 192: "still not very glass-like", 0.6 → 0.35; build 194: further, 0.35 → 0.15 — the blur
    /// alone keeps the titles and buttons legible).
    static let groundOpacity: Double = 0.15
    /// The fade's ease (smoothstep): from the header's bottom (`at` 0) to the frost's end (`at` 1).
    static let fadeCurve: [(at: CGFloat, alpha: Double)] = stride(from: 0, through: 8, by: 1).map {
        let step = Double($0) / 8
        return (CGFloat(step), 1 - step * step * (3 - 2 * step))
    }
    /// How far past the header's own height it travels to clear the status bar.
    static let clearance: CGFloat = 80
    /// The header settling all there or all away once a scroll stops.
    static let slide: Animation = .smooth(duration: 0.24)
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
