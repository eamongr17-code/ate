import SwiftUI

/// **A tab root's header** — the title leading and the root's glass group trailing, on ONE row: the
/// header wastes no space. The Journal's title is the wordmark (never typeset); Feed, Search and You
/// use their names; the Feed's city rides as the subtitle. No eyebrow text, no frost.
///
/// ``SwiftUICore/View/ateRootToolbar(title:subtitle:controls:)`` puts the same row into the native
/// navigation bar — the title as a leading item with no glass of its own, the controls as the
/// system's own trailing glass group — which is how a screen uses it. The view is the gallery's
/// stand-in for that bar and the title item's contents.
struct AteRootHeader<Controls: View>: View {
    let title: AteRootHeaderTitle
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            AteRootTitle(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            AteGlassGroup { controls }
        }
        .padding(.leading, title == .wordmark ? AteRootHeaderMetrics.wordmarkLeading : AteMetrics.gutter)
        .padding(.trailing, AteRootHeaderMetrics.trailing)
        .frame(height: AteMetrics.hit)
    }
}

/// What a root is titled by: the Journal's wordmark, or a name.
enum AteRootHeaderTitle: Equatable {
    case wordmark
    case text(String)
}

/// The header's title: the wordmark, or the name with its subtitle beside it on the baseline.
struct AteRootTitle: View {
    let title: AteRootHeaderTitle
    var subtitle: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        switch title {
        case .wordmark:
            AteWordmark(height: AteRootHeaderMetrics.wordmark)
        case .text(let name):
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(name)
                    .ateText(.kitRootTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .ateText(.kitRootSubtitle)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
        }
    }
}

enum AteRootHeaderMetrics {
    /// `.wm{left:16px; height:32px}`; `.lt{left:20px}`; the group `right:16px`.
    static let wordmark: CGFloat = 32
    static let wordmarkLeading: CGFloat = 16
    static let trailing: CGFloat = 16
    /// `.it{gap:1px}` — the inline title over its subtitle.
    static let inlineGap: CGFloat = 1
    /// How far a root scrolls before its title collapses: half the 44pt header row.
    static let collapseAfter: CGFloat = 22
    /// The hand-over between the root title and the inline one.
    static let collapse: Animation = .smooth(duration: 0.25)
}

/// **An inline bar title** — a pushed page's name (or byline), and a tab root's title once it has
/// collapsed into the bar, leading-aligned on every screen: the name at 17, and an optional muted
/// subtitle under it (the Feed's city). A leading item in the native bar; the bar, its glass and
/// its scroll-edge effect are the system's.
struct AteInlineTitle: View {
    let title: String
    var subtitle: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteRootHeaderMetrics.inlineGap) {
            Text(title)
                .ateText(.kitInlineTitle)
                .foregroundStyle(palette.fg)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .ateText(.kitInlineSubtitle)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Installs a tab root's header in the **native** navigation bar: the title as a leading toolbar
    /// item with its shared glass hidden, and the controls as the system's trailing glass group.
    ///
    /// Scrolled (`isCollapsed`, from ``ateRootCollapse(_:)``), the leading title gives way to
    /// `inline` in the bar's own title slot — the Journal's month, the Feed's name over its city —
    /// under the system's own scroll-edge effect, leading-aligned like every inline title. The
    /// controls stay where they are.
    func ateRootToolbar<Controls: View>(
        title: AteRootHeaderTitle,
        subtitle: String? = nil,
        inline: AteInlineTitle? = nil,
        isCollapsed: Bool = false,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        let controls = controls()
        let showsInline = isCollapsed && inline != nil
        return toolbar {
            if showsInline == false {
                ToolbarItem(placement: .topBarLeading) {
                    AteRootTitle(title: title, subtitle: subtitle)
                        // The bar would squeeze a toolbar item to "F…"; the title is never truncated.
                        .fixedSize()
                        .accessibilityIdentifier("root.title")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if showsInline, let inline {
                ToolbarItem(placement: .topBarLeading) {
                    inline.accessibilityIdentifier("root.inlineTitle")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                controls
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .animation(AteRootHeaderMetrics.collapse, value: showsInline)
    }

    /// A pushed page's inline title, leading — beside the system's back — exactly where a collapsed
    /// root's title sits. iOS 26 centres a bar title only when it fits evenly between the side items,
    /// so its own title slot put the name centred on some screens and leading on others; every
    /// inline title is a leading item instead, and the system's title is removed.
    func ateInlineTitle(_ title: String, subtitle: String? = nil) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AteInlineTitle(title: title, subtitle: subtitle)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    /// Reports whether a tab root's scroll view has moved far enough for its header to collapse —
    /// half the header row. Apply to the root's own `ScrollView` or `List`.
    func ateRootCollapse(_ isCollapsed: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > AteRootHeaderMetrics.collapseAfter
        } action: { _, collapsed in
            isCollapsed.wrappedValue = collapsed
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}
