import SwiftUI

/// **A labelled glass toggle in the bar** — a category page's Follow / Following (`discover.html`
/// `.fol`): an icon and a word on the system's own toolbar glass (the item is a `ToolbarItem`; the bar
/// draws the capsule). Off is `+ Follow`, on is `✓ Following`, with a selection haptic on the flip.
///
/// `.fol{height:44px; gap:6px; padding:0 16px 0 12px; font:600 16px}`; the icon 18.
struct AteGlassLabelToggle: View {
    let offTitle: String
    let onTitle: String
    let offIcon: AteIcon
    let onIcon: AteIcon
    let isOn: Bool
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteGlassLabelToggleMetrics.gap) {
                (isOn ? onIcon : offIcon).view(size: AteGlassLabelToggleMetrics.icon)
                Text(isOn ? onTitle : offTitle)
                    .ateText(.kitInkPill)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(palette.fg)
            .padding(.leading, AteGlassLabelToggleMetrics.leading)
            .padding(.trailing, AteGlassLabelToggleMetrics.trailing)
            .frame(height: AteMetrics.hit)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(offTitle)
        .accessibilityValue(isOn ? onTitle : "")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "glass.toggle")
    }
}

enum AteGlassLabelToggleMetrics {
    static let gap: CGFloat = 6
    static let icon: CGFloat = 18
    /// `padding:0 16px 0 12px`, less the bar's own 4 inside a toolbar item's glass.
    static let leading: CGFloat = 12 - AteGlassGroupMetrics.padding
    static let trailing: CGFloat = 16 - AteGlassGroupMetrics.padding
}
