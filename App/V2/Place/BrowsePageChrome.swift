import AteKit
import SwiftUI

/// **How a Browse page sits in the native bar** (place, dish): the page's name in the content at rest
/// and in the bar once it has scrolled under it (``SwiftUICore/View/ateTitleCollapse(_:after:)``), and
/// the tab bar staying put. Shared by the place and dish pages, which are one lane's.
extension View {
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
        AteEmptyState(line: "Couldn't\nreach Ate.", art: .unplugged, pill: (title: "Try again", action: retry))
            .accessibilityIdentifier("state.unreachable")
    }
}
