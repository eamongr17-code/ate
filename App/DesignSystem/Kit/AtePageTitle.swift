import SwiftUI

/// **A pushed page's header** (`page-headers.html`, approved 24 Oct) — every page about one thing (a
/// list, a place, a dish, a tag, a person) and every pushed page with a name of its own (notifications,
/// what you follow) opens the same way, always left: its picture if it has one, 18 above the name;
/// the name in Young Serif at 34 on up to three lines; one muted line 8 under it; its buttons or
/// chips 16 under that. Once the name has scrolled under the bar the bar takes it
/// (``SwiftUICore/View/ateTitleCollapse(_:after:)``, ``SwiftUICore/View/ateCollapsingTitle(_:subtitle:isCollapsed:)``).
struct AtePageHeader<Art: View, Line: View, Below: View>: View {
    let title: String
    /// Where the name ends, measured from the header's top: the page's first row, so the same
    /// distance the page scrolls before the name is under the bar.
    var titleBottom: Binding<CGFloat>?
    let art: Art
    let line: Line
    let below: Below

    init(
        _ title: String,
        titleBottom: Binding<CGFloat>? = nil,
        @ViewBuilder art: () -> Art = { EmptyView() },
        @ViewBuilder line: () -> Line = { EmptyView() },
        @ViewBuilder below: () -> Below = { EmptyView() }
    ) {
        self.title = title
        self.titleBottom = titleBottom
        self.art = art()
        self.line = line()
        self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Art.self != EmptyView.self {
                art.padding(.bottom, AtePageHeaderMetrics.artGap)
            }
            AteExactText(
                text: title, style: .pageHeaderTitle, alignment: .leading, lineLimit: AtePageHeaderMetrics.lines
            )
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(AtePageHeaderMetrics.space)).maxY
                } action: { titleBottom?.wrappedValue = $0 }
            if Line.self != EmptyView.self {
                line.padding(.top, AtePageHeaderMetrics.lineGap)
            }
            if Below.self != EmptyView.self {
                below.padding(.top, AtePageHeaderMetrics.belowGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AtePageHeaderMetrics.top)
        .coordinateSpace(.named(AtePageHeaderMetrics.space))
    }
}

/// **A pushed page's own title, nothing else** — notifications, what you follow, a tag (its city on
/// the line under it): ``AtePageHeader`` with only a name and, if it has one, a muted line.
struct AtePageTitle: View {
    let title: String
    var subtitle: String?
    var titleBottom: Binding<CGFloat>?

    @Environment(\.atePalette) private var palette

    var body: some View {
        AtePageHeader(title, titleBottom: titleBottom) {
            EmptyView()
        } line: {
            if let subtitle {
                Text(subtitle)
                    .ateText(.pageHeaderLine)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, AtePageHeaderMetrics.titleFoot)
        .accessibilityElement(children: .combine)
    }
}

enum AtePageHeaderMetrics {
    /// The header's top, under the bar.
    static let top: CGFloat = 8
    /// The picture's foot to the name.
    static let artGap: CGFloat = 18
    /// The name's foot to its line.
    static let lineGap: CGFloat = 8
    /// The line (or the name) to the buttons or chips.
    static let belowGap: CGFloat = 16
    /// A long name wraps to three lines before it ends on an ellipsis.
    static let lines = 3
    /// A title-only header's room before the page's content.
    static let titleFoot: CGFloat = 20
    /// A list cover in the header.
    static let cover: CGFloat = 160
    /// A person's avatar in the header.
    static let avatar: CGFloat = 72
    static let space = "ate.page.header"
}

extension View {
    /// A pushed page with its own header (``AtePageHeader``): nothing in the bar at rest but the back
    /// and the page's trailing items; once the name has scrolled under the bar (``ateTitleCollapse(_:after:)``)
    /// it takes the bar's leading slot. The bar lies on the glass bar (``ateHeaderGlass()``),
    /// as every bar does.
    func ateCollapsingTitle(_ title: String?, subtitle: String? = nil, isCollapsed: Bool) -> some View {
        navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if isCollapsed, let title {
                    ToolbarItem(placement: .topBarLeading) {
                        AteInlineTitle(title: title, subtitle: subtitle)
                            .accessibilityIdentifier("page.inlineTitle")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .animation(AteRootHeaderMetrics.collapse, value: isCollapsed)
            .ateHeaderGlass()
    }

    /// Reports whether the page has scrolled its header's name under the bar: past `titleBottom`
    /// (``AtePageHeader``'s), measured from the top of the scrolled content. The same moment on
    /// every pushed page (`scroll-headers.html`). Apply to the page's own `ScrollView` or `List`.
    func ateTitleCollapse(_ isCollapsed: Binding<Bool>, after titleBottom: CGFloat) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            titleBottom > 0 && geometry.contentOffset.y + geometry.contentInsets.top > titleBottom
        } action: { _, collapsed in
            isCollapsed.wrappedValue = collapsed
        }
    }

    /// A pushed page that lays out its own bar items (the entry page: its byline or place, Share,
    /// •••): the inline bar, the system's title removed, on the glass bar like every other
    /// pushed page (``ateInlineTitle(_:subtitle:)``, ``ateCollapsingTitle(_:subtitle:isCollapsed:)``).
    func atePushedBar() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .ateHeaderGlass()
    }
}
