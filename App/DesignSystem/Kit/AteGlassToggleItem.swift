import SwiftUI

/// **A control in a root's glass group that can be on** — the Journal's calendar while the page is
/// zoomed out, and its filter while a filter is on (`.hit.onink`): the same icon in the same 36 × 44
/// slot as an ``AteGlassItem``, and, when on, a 36 ink disc behind it with the glyph in the colour
/// written on ink. Off, it is exactly an ``AteGlassItem``.
struct AteGlassToggleItem: View {
    let icon: AteIcon
    let label: String
    let isOn: Bool
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            icon.view(size: AteGlassDiscMetrics.glyph)
                .foregroundStyle(isOn ? palette.inverted : palette.fg)
                .frame(width: AteGlassGroupMetrics.slot, height: AteGlassGroupMetrics.slot)
                .background {
                    if isOn {
                        Circle().fill(palette.solid)
                    }
                }
                .frame(width: AteGlassGroupMetrics.slot, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "glass.\(label.lowercased())")
    }
}
