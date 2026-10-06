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

enum AteHeaderGroundMetrics {
    /// The ground is off at rest and on once the content has gone this far under the bar.
    static let showAfter: CGFloat = 4
    /// The switch is a short step, not a scroll-driven fade (Eamon, build 94).
    static let switchDuration: Double = 0.15
}

/// ``SwiftUICore/View/ateHeaderGround()``: the ground over the bar, there once the page has
/// scrolled under it and gone at rest.
private struct AteHeaderGround: ViewModifier {
    @State private var shown: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > AteHeaderGroundMetrics.showAfter
            } action: { _, scrolled in
                // The same ground as always, there or not (Eamon, build 94: no faded header): it
                // switches in a short step the moment content goes under the bar, never by degrees.
                withAnimation(.easeOut(duration: AteHeaderGroundMetrics.switchDuration)) {
                    shown = scrolled ? 1 : 0
                }
            }
            // The ground is the bar's only edge: the system's scroll-edge effect drew a lighter band and a
            // line over the page even at rest (build 92).
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let bar = proxy.safeAreaInsets.top
                    let ground = AtePalette.automatic.ground
                    // A hard edge at the bar's bottom, no gradient (Eamon, build 95: "faded" meant the
                    // soft edge).
                    ground
                        .frame(height: bar)
                        .ignoresSafeArea(edges: .top)
                }
                .opacity(shown)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
    /// How far a root scrolls before its title collapses: half the 44pt header row…
    static let collapseAfter: CGFloat = 22
    /// …and how far back it must come before the root title returns: a band either side, so a slow
    /// drag around the threshold never flickers between the two.
    static let expandBefore: CGFloat = 8
    /// The hand-over between the root title and the inline one: a plain crossfade.
    static let collapse: Animation = .easeInOut(duration: 0.18)
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
            // ONE leading item that never changes: the root title and the inline one stacked in it,
            // crossfading. Swapping two items made the bar morph them through a blur and re-measure
            // its row, which nudged the scroll offset and re-triggered the collapse (build 88).
            ToolbarItem(placement: .topBarLeading) {
                ZStack(alignment: .leading) {
                    AteRootTitle(title: title, subtitle: subtitle)
                        .accessibilityIdentifier("root.title")
                        .opacity(showsInline ? 0 : 1)
                        .accessibilityHidden(showsInline)
                    if let inline {
                        inline
                            .accessibilityIdentifier("root.inlineTitle")
                            .opacity(showsInline ? 1 : 0)
                            .accessibilityHidden(showsInline == false)
                    }
                }
                // The bar would squeeze a toolbar item to "F…"; the title is never truncated.
                .fixedSize()
                .animation(AteRootHeaderMetrics.collapse, value: showsInline)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                controls
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .ateHeaderGround()
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
            .ateHeaderGround()
    }

    /// **The header's ground** (build 87, note 1): the bar area — from the screen's top edge to just
    /// under the title row's controls — is the page's ground, ending in a hard edge at the bar's bottom (build 95), so
    /// scrolled content is never legible behind the title or the glass. The system's soft
    /// scroll-edge effect alone is too weak over white slips, and `.hard` cuts the content off with
    /// a sharp edge and a blurred ghost above it.
    ///
    /// Only while something is under it (build 92, note 1): at rest the page is one surface — no
    /// band, no edge — and the ground switches in, whole, once the content has gone
    /// ``AteHeaderGroundMetrics/showAfter`` points under the bar, and out again at rest (build 94:
    /// never a scroll-driven fade). It reads the first scroll view inside the page and changes only
    /// its own opacity: the bar's layout never moves.
    ///
    /// Every bar modifier in the kit applies it (``ateRootToolbar``, ``ateInlineTitle``,
    /// ``ateInlineByline``), so roots and pushed pages get it once. Drawn over the page and under
    /// the navigation bar's own items, and never hit-tested.
    func ateHeaderGround() -> some View {
        modifier(AteHeaderGround())
    }

    /// Reports whether a tab root's scroll view has moved far enough for its header to collapse —
    /// half the header row. Apply to the root's own `ScrollView` or `List`.
    func ateRootCollapse(_ isCollapsed: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Hysteresis: collapse past one line, come back only well before it.
            let collapsed = isCollapsed.wrappedValue
            if collapsed == false, offset > AteRootHeaderMetrics.collapseAfter {
                isCollapsed.wrappedValue = true
            } else if collapsed, offset < AteRootHeaderMetrics.expandBefore {
                isCollapsed.wrappedValue = false
            }
        }
    }
}
