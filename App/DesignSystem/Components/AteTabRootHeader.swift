import AteKit
import SwiftUI

/// **A tab root's header that gets out of the way** — the Journal's logo and segment, the Feed's
/// title and area. It scrolls away with the page on the way down, and comes straight back, over the
/// page, the moment the reader scrolls up anywhere in the list (the pattern Safari and Photos use),
/// so the segment and the area are one flick away from any depth.
///
/// The header stays where it always was, in the scroll content, so every position below it — slips,
/// empty states, the refresh control — is where the artboard puts it and the screen's layout is
/// untouched: on the way down it simply scrolls away. On the way up a *compact* header comes back
/// over the list, just under the status bar — the tab's name small and its trailing controls
/// (round 6, ``AteCompactHeader``) — out of a blur into focus, and goes the same way on the next
/// scroll down; back at the top it goes, and the big header in the page is the one there.
///
/// Every tab root also lays the one top frost (round 7, ``AteTopFrost``): nothing at rest, then from
/// the screen's top edge through the status bar — and down through the compact header while it is
/// up — feathering out at its foot.
///
/// It also owns the tab's scroll-to-top: the ScrollView's own top edge, insets included. An anchor on
/// a view in the content lands that view at the top of the visible area, which on the Journal put
/// the logo under the status bar (the round-4 bug: any re-tap, and every other tab's re-tap, since
/// the signal was once shared).
extension View {
    /// Apply to the tab root's `ScrollView`. `scrollToTop` is bumped when the tab is re-tapped.
    /// `jumpToTop` is bumped when the page's content is swapped (the Journal's other shelf): the
    /// top, at once, with nothing animating.
    /// `compact` is what comes back mid-scroll (round 6): an ``AteCompactHeader`` — the tab's name,
    /// small, and its trailing control — never a second copy of the big header.
    func ateTabRootHeader<Compact: View>(
        scrollToTop: Int,
        jumpToTop: Int = 0,
        @ViewBuilder compact: () -> Compact
    ) -> some View {
        modifier(AteTabRootHeader(scrollToTop: scrollToTop, jumpToTop: jumpToTop, compact: compact()))
    }

    /// The compact header alone, for a root that owns its own scroll position (Search): it comes
    /// back on the way up and goes on the way down, with the tab bar following as on every tab.
    func ateCompactHeader<Compact: View>(@ViewBuilder _ compact: () -> Compact) -> some View {
        modifier(AteFloatingCompactHeader(compact: compact()))
    }

    /// A tab root with no floating header (You) still tells the shell which way it is being
    /// scrolled — the tab bar's shadow and its re-expansion follow every tab the same way — and
    /// wears the same top frost.
    func ateTabBarTracking() -> some View {
        modifier(AteTabBarTracking())
    }
}

/// What a tab root's scrolling says about the chrome around it.
struct AteChromeState: Equatable {
    /// The floating header is up.
    var isFloating = false
    /// The tab bar: at full size, or minimised by a scroll down.
    var isBarExpanded = true
}

extension EnvironmentValues {
    /// The tab whose root this is — set once by the shell per tab. `nil` outside the shell (the
    /// gallery, previews), where the tracker only moves the header.
    @Entry var ateTabRoot: AteTab?
}

/// The scroll reading both modifiers share: the direction, and nothing but a person's own scrolling.
/// On the current tab it minimises the tab bar on the way down and brings the whole bar back on the
/// way up (`AteTabChrome`).
private struct AteChromeTracker: ViewModifier {
    @Binding var track: AteHeaderTrack
    /// Only a person's own scrolling picks a direction — not a programmatic scroll, and not the
    /// system moving the content when the bar beside it resizes.
    @State private var isPersonScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ateTabRoot) private var root
    @Environment(AteTabChrome.self) private var chrome: AteTabChrome?

    /// Read through the chrome object, so it is current even on a tab whose content the `TabView`
    /// has not rebuilt.
    private var isCurrentTab: Bool {
        guard let root, let chrome else { return true }
        return chrome.current == root
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: AteHeaderTrack.Sample.self) { geometry in
                AteHeaderTrack.Sample(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    // `containerSize` is already inside the insets.
                    maxOffset: geometry.contentSize.height - geometry.containerSize.height
                )
            } action: { _, sample in
                var next = track
                next.update(sample, isPersonScrolling: isPersonScrolling)
                let state = AteChromeState(isFloating: next.isFloating, isBarExpanded: next.isBarExpanded)
                let was = AteChromeState(isFloating: track.isFloating, isBarExpanded: track.isBarExpanded)
                guard state != was else {
                    track = next
                    return
                }
                // A change of direction brings the header into focus (or lets it go); arriving back
                // at the top just hands over to the header in the page, which is already exactly there.
                let moves = next.offset > AteHeaderTrack.topSlack && reduceMotion == false
                withAnimation(moves ? AteMotion.headerFocus : nil) { track = next }
                report(expanded: next.isBarExpanded)
            }
            .onScrollPhaseChange { _, phase in
                isPersonScrolling = phase == .interacting || phase == .decelerating
            }
            .onChange(of: chrome?.expandRequest ?? 0) { _, _ in
                // The minimised bar was tapped: it is whole again, and the next scroll down has to
                // read as a change.
                guard isCurrentTab else { return }
                track.expandBar()
                report(expanded: true)
            }
            .onChange(of: isCurrentTab) { _, isCurrent in
                // A fling cut short by a tab switch never reports its end: left standing, the
                // system moving this list would read as a person.
                isPersonScrolling = false
                guard isCurrent else { return }
                // Chosen on the full bar: the model goes back to it, and the bar hears the whole
                // state — not only a change — so the two agree before the next scroll (QA on #75).
                track.tabBecameCurrent()
                report(expanded: true)
            }
    }

    private func report(expanded: Bool) {
        guard isCurrentTab, let chrome else { return }
        if chrome.isExpanded != expanded { chrome.isExpanded = expanded }
    }
}

private struct AteTabBarTracking: ViewModifier {
    @State private var track = AteHeaderTrack()

    func body(content: Content) -> some View {
        content
            .modifier(AteChromeTracker(track: $track))
            .overlay(alignment: .top) {
                AteTopFrost(
                    depth: AteFrostMetrics.statusDepth, presence: AteFrostMetrics.presence(offset: track.offset)
                )
                    .ignoresSafeArea(edges: .top)
            }
    }
}

/// The compact header, floating: up after a scroll up mid-list, down on the next scroll down or at
/// the top — where the page's own big header is the one on screen, touched and read aloud.
private struct AteFloatingCompactHeader<Compact: View>: ViewModifier {
    let compact: Compact
    @State private var track = AteHeaderTrack()

    func body(content: Content) -> some View {
        content.modifier(AteFloatingHeaderLayer(track: $track, compact: compact))
    }
}

/// The tracker, the top frost and the floating header, over whatever scroll view carries them. The
/// frost is one surface whose solid part reaches down through the header while it is up, and back
/// to the status bar when it goes.
private struct AteFloatingHeaderLayer<Compact: View>: ViewModifier {
    @Binding var track: AteHeaderTrack
    let compact: Compact

    func body(content: Content) -> some View {
        content
            .modifier(AteChromeTracker(track: $track))
            .overlay(alignment: .top) {
                AteTopFrost(
                    depth: track.isFloating ? AteFrostMetrics.headerDepth : AteFrostMetrics.statusDepth,
                    presence: track.isFloating ? 1 : AteFrostMetrics.presence(offset: track.offset)
                )
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) {
                if track.isFloating {
                    compact
                        .transition(.ateHeaderReturn)
                }
            }
    }
}

private struct AteTabRootHeader<Compact: View>: ViewModifier {
    let scrollToTop: Int
    let jumpToTop: Int
    let compact: Compact

    /// Starts with nothing to seek: an `edge` position is resolved against a list's scroll targets on
    /// its first layout, which landed the Journal on its first slip rather than its top.
    ///
    /// Untyped, so it never holds a slip: typed to the lists' `UUID`s, SwiftUI wrote the top slip
    /// into it as the person scrolled and then held that slip still through every change to the
    /// list — an entry written above it landed out of view (QA). All it does is the re-tap's top.
    @State private var position = ScrollPosition()
    @State private var track = AteHeaderTrack()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .modifier(AteFloatingHeaderLayer(track: $track, compact: compact))
            .onChange(of: scrollToTop) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .top) }
            }
            .onChange(of: jumpToTop) { _, _ in
                var jump = Transaction(animation: nil)
                jump.disablesAnimations = true
                withTransaction(jump) { position.scrollTo(edge: .top) }
            }
    }
}
