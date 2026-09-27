import SwiftUI

/// **The top-corner buttons, in iOS 26's own Liquid Glass** (round 4, Eamon's pick from the
/// exploration) — to match the glass tab bar.
///
/// - **Pushed pages** show the system navigation bar, see-through: the system's glass back button,
///   the page's name or byline after it with no glass of its own, and the page's corner controls as
///   one trailing glass group (`ateNavigationBar`). The navigation bar takes the strip the page's own
///   bar used to draw.
/// - **Tab roots** keep no navigation bar — a bar with only a gear in it would push the page down a
///   whole row — so their corner button wears the same system glass in place (`ateCornerGlass`).
extension View {
    /// A pushed page's navigation bar: `leading` sits after the system back button, bare; `trailing`
    /// is one glass group.
    func ateNavigationBar<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let leading = leading()
        let trailing = trailing()
        return toolbar {
            if Leading.self != EmptyView.self {
                ToolbarItem(placement: .topBarLeading) { leading }
                    .sharedBackgroundVisibility(.hidden)
            }
            if Trailing.self != EmptyView.self {
                ToolbarItemGroup(placement: .topBarTrailing) { trailing }
            }
        }
    }

    /// A tab root's corner button in the system's interactive glass, in place.
    func ateCornerGlass() -> some View {
        glassEffect(.regular.interactive(), in: .circle)
    }

    /// The shell's half, on every pushed page: the navigation bar shown, see-through, with no title
    /// of its own (a page that has a name puts it in `leading`, in the app's type).
    func ateNavigationBarHost() -> some View {
        toolbar(.visible, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A pushed page's name, as the navigation bar carries it: `.h` at 24, one line.
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
