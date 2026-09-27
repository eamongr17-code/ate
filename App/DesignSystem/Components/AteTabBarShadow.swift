import SwiftUI

/// **A very light shadow under the glass tab bar** (round 4, Eamon's pick) — so the bar parts from
/// the linen while the glass stays exactly the system's: no fill, no stroke, nothing on it.
///
/// Public API only. SwiftUI shapes of the bar's footprint — the tab capsule and the `+` circle —
/// drawn in each tab root, *under* the native bar, with the shadow masked to outside the shapes:
/// a shadow behind translucent glass would show through it and grey the glass, which is smoked, the
/// one thing the glass must never be. It is laid out from the top of the bar's strip down (the tab
/// root's content ends where the bar begins).
///
/// iOS 26 gives no public reading of the bar's minimised state, so the shell shows this only while
/// the app's own model says the bar is at full size (``AteChromeState/isBarExpanded``) and fades it
/// with the bar as it minimises; the minimised bar has no shadow.
struct AteTabBarShadow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shadow = colorScheme == .dark ? AteShadow.tabBarDark : AteShadow.tabBarLight
        footprint(fill: shadow.colour)
            .blur(radius: shadow.blur / 2)
            .offset(y: shadow.offsetY)
            .mask {
                // Everything but the glass itself.
                Rectangle()
                    .padding(-shadow.blur * 2)
                    .overlay { footprint(fill: .black).blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .frame(height: Self.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// iOS 26's bar on a phone: a 62pt capsule for the tabs and a 62pt circle for `+`, 21 in from
    /// each side and 8 apart, its top at the top of the bar's strip.
    private func footprint(fill: Color) -> some View {
        HStack(spacing: Self.gap) {
            Capsule().fill(fill)
            Circle().fill(fill).frame(width: Self.height)
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.inset)
    }

    static let height: CGFloat = 62
    private static let inset: CGFloat = 21
    private static let gap: CGFloat = 8
}
