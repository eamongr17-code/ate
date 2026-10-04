import SwiftUI

/// **A pushed page's own large title** (`discover.html` `.ptitle`) — the page's name in Bricolage 800,
/// an optional muted subtitle on its baseline (a category's city), sitting 12 under the bar and
/// leaving the band to 176 before the content. It scrolls away with the content; the page puts
/// ``AteInlineTitle`` in the bar once it has (``SwiftUICore/View/ateCollapsingTitle(_:subtitle:isCollapsed:)``).
///
/// `.ptitle{left:20px; top:112px; align-items:baseline; gap:8px}`, `span{500 16px muted}`.
struct AtePageTitle: View {
    let title: String
    var subtitle: String?
    var isLong = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(title)
                .ateText(isLong ? .kitPageTitleLong : .kitPageTitle)
                .foregroundStyle(palette.fg)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .ateText(.kitRootSubtitle)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AtePageTitleMetrics.top)
        .frame(maxWidth: .infinity, minHeight: AtePageTitleMetrics.band, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

enum AtePageTitleMetrics {
    /// The title's top, 12 under the bar (`top:112px` against the bar's foot at 100).
    static let top: CGFloat = 12
    /// From the bar's foot to the content (`top:176px`).
    static let band: CGFloat = 76
}

extension View {
    /// A pushed page with its own large title (``AtePageTitle``): nothing in the bar at rest but the
    /// back and the page's trailing items; once the title has scrolled under the bar
    /// (``atePageCollapse(_:)``), the name and its subtitle take the bar's leading slot, as a root's do.
    /// The bar lies on the header's ground (``ateHeaderGround()``), as every pushed page's does.
    func ateCollapsingTitle(_ title: String, subtitle: String? = nil, isCollapsed: Bool) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if isCollapsed {
                    ToolbarItem(placement: .topBarLeading) {
                        AteInlineTitle(title: title, subtitle: subtitle)
                            .accessibilityIdentifier("page.inlineTitle")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .animation(AteRootHeaderMetrics.collapse, value: isCollapsed)
            .ateHeaderGround()
    }

    /// ``ateRootCollapse(_:)`` for a pushed page with its own large title: the same half-row
    /// threshold, under the soft scroll edge every pushed page has. (The roots' `.hard` edge drew a
    /// hairline and a blurred ghost of the content under a pushed bar — build 88.)
    func atePageCollapse(_ isCollapsed: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > AteRootHeaderMetrics.collapseAfter
        } action: { _, collapsed in
            isCollapsed.wrappedValue = collapsed
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// A pushed page that lays out its own bar items (the entry page: its byline or place, Share,
    /// •••): the inline bar, the system's title removed, on the header's ground like every other
    /// pushed page (``ateInlineTitle(_:subtitle:)``, ``ateCollapsingTitle(_:subtitle:isCollapsed:)``).
    func atePushedBar() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .ateHeaderGround()
    }
}
