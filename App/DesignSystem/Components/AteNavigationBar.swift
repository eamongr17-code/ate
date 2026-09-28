import SwiftUI

/// **A pushed page's top bar, in the app's own glass** (round 5: in place of the system navigation
/// bar and its Liquid Glass buttons, which clashed with the custom chrome around them).
///
/// The same layout the system bar gave the page: a 54pt strip under the status bar, the back button
/// (a 44 glass disc with the ported back mark) 16 in from the leading edge, the page's name or
/// byline after it with no glass of its own, and the page's corner controls as one glass group 16
/// in from the trailing edge. The page's content keeps the inset the system bar gave it, so nothing
/// under the bar moves. The left-edge swipe back is `ateSwipeBack`'s, as before.
///
/// Under the bar, the one top frost (round 7, ``AteTopFrost``): nothing while the page is at its top,
/// then solid from the screen's top edge to just below the bar's controls, feathering out below.
extension View {
    /// A pushed page's top bar: `leading` sits after the back button, bare; `trailing` is one glass
    /// group.
    func ateNavigationBar<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        modifier(AteNavigationBarModifier(leading: leading(), trailing: trailing()))
    }

    /// A tab root's corner button in the chrome's glass, in place.
    func ateCornerGlass() -> some View {
        ateGlass(in: Circle())
    }

    /// The shell's half, on every pushed page: no system bars (the page draws its own top bar, and
    /// the tab bar belongs to the tab's root), and the ground behind the whole page — the root and
    /// its tab bar are under it.
    func ateNavigationBarHost() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .background(AtePalette.automatic.ground.ignoresSafeArea())
    }
}

private struct AteNavigationBarModifier<Leading: View, Trailing: View>: ViewModifier {
    let leading: Leading
    let trailing: Trailing
    @Environment(\.dismiss) private var dismiss
    /// How far the page's scroll view has moved from its top — what brings the frost in.
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, now in
                offset = now
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: AteNavigationBarMetrics.leadingGap) {
                    AteGlassButton(icon: .back, label: "Back", size: AteNavigationBarMetrics.backIcon) { dismiss() }
                        .accessibilityIdentifier("nav.back")
                    if Leading.self != EmptyView.self {
                        leading
                    }
                    Spacer(minLength: 0)
                    if Trailing.self != EmptyView.self {
                        AteGlassGroup { trailing }
                    }
                }
                .padding(.horizontal, AteNavigationBarMetrics.inset)
                .frame(height: AteMetrics.navigationBar, alignment: .top)
                .background(alignment: .top) {
                    AteTopFrost(depth: AteFrostMetrics.barDepth, presence: AteFrostMetrics.presence(offset: offset))
                        .ignoresSafeArea(edges: .top)
                }
            }
    }
}

enum AteNavigationBarMetrics {
    /// Read off iOS 26's bar (build 80): the back disc and the group 16 in, the name 16 after the disc.
    static let inset: CGFloat = 16
    static let leadingGap: CGFloat = 16
    /// The system chevron was 18 tall; the back mark (Lucide chevron-left) reaches that at 34.
    static let backIcon: CGFloat = 34
}

/// A pushed page's name, as the top bar carries it: `.h` at 24, one line.
struct AteNavigationTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .ateText(.pageTitle)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}
