import SwiftUI

/// **A root's controls on one piece of glass** — at most three icons, trailing, in one Liquid Glass
/// capsule (`.grp`: 44 high, `padding:0 4px`, each control a 36-wide slot). The Journal's photos,
/// calendar and filter; the Feed's area and cravings; Search's filter; You's settings.
///
/// A fourth control is not drawn: the contract caps a root at three.
struct AteGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { controls in
            if controls.isEmpty == false {
                GlassEffectContainer {
                    HStack(spacing: 0) {
                        ForEach(controls.prefix(AteGlassGroupMetrics.maximum)) { $0 }
                    }
                    .padding(.horizontal, AteGlassGroupMetrics.padding)
                    .frame(height: AteMetrics.hit)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

enum AteGlassGroupMetrics {
    static let maximum = 3
    /// `padding:0 4px`, and each control's slot `width:36px`.
    static let padding: CGFloat = 4
    static let slot: CGFloat = 36
    /// The badge: `top:3px; right:1px; min-width:17px; height:17px; padding:0 4px`.
    static let badge: CGFloat = 17
    static let badgePadding: CGFloat = 4
    static let badgeTop: CGFloat = 3
    static let badgeTrailing: CGFloat = 1
}

/// One control in an ``AteGlassGroup``: an icon in its 36 × 44 slot, with an optional coral count
/// (the Journal's photos waiting to be written up).
struct AteGlassItem: View {
    let icon: AteIcon
    let label: String
    var badge: Int?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteGlassItemFace(icon: icon, badge: badge)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.fg)
        .accessibilityLabel(label)
        .accessibilityValue(badge.map { "\($0)" } ?? "")
    }
}

private struct AteGlassItemFace: View {
    let icon: AteIcon
    let badge: Int?

    var body: some View {
        icon.view(size: AteGlassDiscMetrics.glyph)
            .frame(width: AteGlassGroupMetrics.slot, height: AteMetrics.hit)
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(verbatim: "\(badge)")
                        .ateText(.kitBadge)
                        .monospacedDigit()
                        .padding(.horizontal, AteGlassGroupMetrics.badgePadding)
                        .frame(minWidth: AteGlassGroupMetrics.badge, minHeight: AteGlassGroupMetrics.badge)
                        .foregroundStyle(AteKitColor.badgeInk)
                        .background(AteKitColor.badge, in: .capsule)
                        .padding(.top, AteGlassGroupMetrics.badgeTop)
                        .padding(.trailing, AteGlassGroupMetrics.badgeTrailing)
                }
            }
            .contentShape(.rect)
    }
}
