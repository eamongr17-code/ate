import SwiftUI

/// **A glass-group control with an ink count** — You's bell ("Ate with", option A): the icon in its
/// 36 × 44 slot of the root's one glass group, and while anything is waiting an INK count on it
/// (`.badge{background:ink; color:#fff}`), never coral — nothing here asks to be looked at, the bell
/// only has to be findable. The count sits where ``AteGlassItem``'s coral one does, at the same size,
/// so the group reads as one control family. Dark mode inverts it with the ink tokens.
struct AteGlassCountItem: View {
    let icon: AteIcon
    let label: String
    var waiting: Int = 0
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            icon.view(size: AteGlassDiscMetrics.glyph)
                .frame(width: AteGlassGroupMetrics.slot, height: AteMetrics.hit)
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Text(verbatim: "\(waiting)")
                            .ateText(.kitBadge)
                            .monospacedDigit()
                            .padding(.horizontal, AteGlassGroupMetrics.badgePadding)
                            .frame(minWidth: AteGlassGroupMetrics.badge, minHeight: AteGlassGroupMetrics.badge)
                            .foregroundStyle(palette.inverted)
                            .background(palette.solid, in: .capsule)
                            .padding(.top, AteGlassGroupMetrics.badgeTop)
                            .padding(.trailing, AteGlassGroupMetrics.badgeTrailing)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.fg)
        .accessibilityLabel(label)
        .accessibilityValue(waiting > 0 ? "\(waiting)" : "")
        .accessibilityIdentifier(identifier ?? "glass.\(label.lowercased())")
    }
}
