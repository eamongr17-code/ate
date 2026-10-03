import AteKit
import SwiftUI

/// **How a Browse page sits in the native bar** (place, dish, tag): the system's inline bar and back,
/// the page's name in the content at rest and in the bar once it has scrolled under it, the system's
/// scroll-edge effect, and the tab bar staying put. Shared by the place and dish pages, which are one
/// lane's.
extension View {
    /// The page's name as the bar's leading title — shown only while `isShown` (its in-content title
    /// has scrolled away). The system's own title slot is removed, as on every inline title.
    func browseBarTitle(_ title: String?, isShown: Bool) -> some View {
        navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if isShown, let title {
                    ToolbarItem(placement: .topBarLeading) {
                        AteInlineTitle(title: title)
                            .accessibilityIdentifier("page.inlineTitle")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .animation(AteRootHeaderMetrics.collapse, value: isShown)
    }

    /// Reports whether the page has scrolled past `threshold` — the bottom of its in-content title,
    /// measured in the scrolled content.
    func browseCollapse(_ isCollapsed: Binding<Bool>, after threshold: CGFloat) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            threshold > 0 && geometry.contentOffset.y + geometry.contentInsets.top > threshold
        } action: { _, collapsed in
            isCollapsed.wrappedValue = collapsed
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Measures where this view ends in the page's scrolled content (``BrowsePage/content``).
    func browseTitleBottom(_ bottom: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(BrowsePage.content)).maxY
        } action: { bottom.wrappedValue = $0 }
    }

    /// A page-level state with nothing under it ("This place isn't here", "Couldn't reach Ate"),
    /// centred in the room the page has.
    func browseFillsPage() -> some View {
        containerRelativeFrame(.vertical) { height, _ in height * BrowsePage.emptyShare }
    }
}

@MainActor
enum BrowsePage {
    /// The scrolled content's coordinate space.
    nonisolated static let content = "browse.page.content"
    /// How much of the page a lone state takes: the visible height less the bars it sits between.
    nonisolated static let emptyShare: CGFloat = 0.7

    /// The one failure a page shows when the phone or the server let it down: the line, and a retry.
    static func unreachable(retry: @escaping () -> Void) -> some View {
        AteEmptyState(line: "Couldn't\nreach Ate.", pill: (title: "Try again", action: retry))
            .accessibilityIdentifier("state.unreachable")
    }
}
