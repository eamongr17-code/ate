import AteKit
import SwiftUI

/// **A tab root's header that gets out of the way** — the Journal's logo and segment, the Feed's
/// title and area. It scrolls away with the page on the way down, and comes straight back, over the
/// page, the moment the reader scrolls up anywhere in the list (the pattern Safari and Photos use),
/// so the segment and the area are one flick away from any depth.
///
/// The header stays where it always was, in the scroll content, so every position below it — slips,
/// empty states, the refresh control — is where the artboard puts it and the screen's layout is
/// untouched: on the way down it simply scrolls away. On the way up a second copy of the same view
/// slides in over the list, pinned where the header rests, and slides back out on the next scroll
/// down; back at the top it goes, and the header in the page is the one there again.
///
/// It also owns the tab's scroll-to-top: the ScrollView's own top edge, insets included. An anchor on
/// a view in the content lands that view at the top of the visible area, which on the Journal put
/// the logo under the status bar (the round-4 bug: any re-tap, and every other tab's re-tap, since
/// the signal was once shared).
extension View {
    /// Apply to the tab root's `ScrollView`. `scrollToTop` is bumped when the tab is re-tapped.
    func ateTabRootHeader<Header: View>(
        scrollToTop: Int,
        @ViewBuilder header: () -> Header
    ) -> some View {
        modifier(AteTabRootHeader(scrollToTop: scrollToTop, header: header()))
    }

    /// A tab root with no floating header (Search, You) still tells the shell which way it is being
    /// scrolled — the tab bar's shadow and its re-expansion follow every tab the same way.
    func ateTabBarTracking() -> some View {
        modifier(AteTabBarTracking())
    }
}

/// What a tab root's scrolling says about the chrome around it.
struct AteChromeState: Equatable {
    /// The floating header is up — and the shell holds the tab bar open with it.
    var isFloating = false
    /// The app's model of the glass tab bar: at full size, or minimised by a scroll down.
    var isBarExpanded = true
}

extension EnvironmentValues {
    /// Told whenever the current tab root's chrome changes, so the shell can bring the whole tab bar
    /// back with a scroll up (the system's minimised bar only re-expands after a long way up) and
    /// show the bar's shadow only when the bar is at full size.
    @Entry var ateChromeChanged: (AteChromeState) -> Void = { _ in }
    /// Whether this tab root's tab is the one on screen — set by the shell per tab.
    @Entry var ateIsCurrentTab = true
}

/// The scroll reading both modifiers share: the direction, and nothing but a person's own scrolling.
private struct AteChromeTracker: ViewModifier {
    @Binding var track: AteHeaderTrack
    /// Only a person's own scrolling picks a direction — not a programmatic scroll, and not the
    /// system moving the content when the bar beside it resizes.
    @State private var isPersonScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ateChromeChanged) private var onChanged
    @Environment(\.ateIsCurrentTab) private var isCurrentTab

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
                // A change of direction slides the header; arriving back at the top just hands over
                // to the header in the page, which is already exactly there.
                let slides = next.offset > AteHeaderTrack.topSlack && reduceMotion == false
                withAnimation(slides ? AteMotion.headerSlide : nil) { track = next }
                onChanged(state)
            }
            .onScrollPhaseChange { _, phase in
                isPersonScrolling = phase == .interacting || phase == .decelerating
            }
            .onChange(of: isCurrentTab) { _, isCurrent in
                // A fling cut short by a tab switch never reports its end: left standing, the
                // system moving this list (the bar resizing beside it) would read as a person.
                isPersonScrolling = false
                guard isCurrent else { return }
                // Chosen on the full bar: the model goes back to it, and the shell hears the whole
                // state — not only a change — so the two agree before the next scroll (QA on #75).
                track.tabBecameCurrent()
                onChanged(AteChromeState(isFloating: track.isFloating, isBarExpanded: track.isBarExpanded))
            }
    }
}

private struct AteTabBarTracking: ViewModifier {
    @State private var track = AteHeaderTrack()

    func body(content: Content) -> some View {
        content.modifier(AteChromeTracker(track: $track))
    }
}

private struct AteTabRootHeader<Header: View>: ViewModifier {
    let scrollToTop: Int
    let header: Header

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
            .modifier(AteChromeTracker(track: $track))
            .overlay(alignment: .top) {
                // Only while it is needed: back over the list. At the top (and pulled past it) the
                // header in the content is the one on screen, touched and read aloud.
                if track.isFloating {
                    header
                        .background {
                            // The status bar's strip too, so a header back over the middle of the
                            // list does not have slips running behind the clock above it.
                            AtePalette.automatic.ground.ignoresSafeArea(edges: .top)
                        }
                        .transition(
                            .move(edge: .top).combined(with: .offset(y: -AteScreen.safeArea.top))
                        )
                }
            }
            .onChange(of: scrollToTop) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .top) }
            }
    }
}
