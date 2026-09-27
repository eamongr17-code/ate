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
}

private struct AteTabRootHeader<Header: View>: ViewModifier {
    let scrollToTop: Int
    let header: Header

    /// Starts with nothing to seek: an `edge` position is resolved against a list's scroll targets on
    /// its first layout, which landed the Journal on its first slip rather than its top.
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var track = AteHeaderTrack()
    /// Only a person's own scrolling picks a direction — not a programmatic scroll, and not the
    /// system moving the content when the bar beside it resizes.
    @State private var isPersonScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ateHeaderRevealed) private var onRevealed

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: AteHeaderTrack.Sample.self) { geometry in
                AteHeaderTrack.Sample(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    // `containerSize` is already inside the insets.
                    maxOffset: geometry.contentSize.height - geometry.containerSize.height
                )
            } action: { _, sample in
                var next = track
                next.update(sample, isPersonScrolling: isPersonScrolling)
                guard next.isFloating != track.isFloating else {
                    track = next
                    return
                }
                // A change of direction slides it; arriving back at the top just hands over to the
                // header in the page, which is already exactly there.
                let slides = next.offset > AteHeaderTrack.topSlack && reduceMotion == false
                withAnimation(slides ? AteMotion.headerSlide : nil) { track = next }
                onRevealed(next.isFloating)
            }
            .onScrollPhaseChange { _, phase in
                isPersonScrolling = phase == .interacting || phase == .decelerating
            }
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

extension EnvironmentValues {
    /// Told whenever a tab root's header comes back (`true`) or slides away (`false`) — so the shell
    /// can bring the whole tab bar back with it. The system's minimised bar only re-expands after a
    /// long way up; the design wants both back at the first flick up.
    @Entry var ateHeaderRevealed: (Bool) -> Void = { _ in }
}
