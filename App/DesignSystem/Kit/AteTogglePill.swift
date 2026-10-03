import SwiftUI

/// **A choice that toggles in place** — the cravings sheet's `.pk`: 42 high, Bricolage 600 at 16,
/// the field colour when off and ink with light lettering when on. Many can be on; the sheet's ink
/// pill commits them. A 44 target.
struct AteTogglePill: View {
    let title: String
    var isOn = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(.kitInkPill)
                .lineLimit(1)
                .padding(.horizontal, AteTogglePillMetrics.padding)
                .frame(height: AteTogglePillMetrics.height)
                .foregroundStyle(isOn ? palette.inverted : palette.fg)
                .background(isOn ? palette.solid : palette.field, in: .capsule)
                .padding(.vertical, AteTogglePillMetrics.hitOutset)
                .contentShape(.rect)
                .padding(.vertical, -AteTogglePillMetrics.hitOutset)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "toggle.\(title)")
    }
}

/// Toggle pills in wrapping rows (`.pks{flex-wrap:wrap; gap:8px}`).
struct AteTogglePillFlow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        AteFlow(spacing: AteMetrics.snug) { content }
    }
}

enum AteTogglePillMetrics {
    /// `.pk{height:42px; padding:0 16px}`.
    static let height: CGFloat = 42
    static let padding: CGFloat = 16
    static let hitOutset: CGFloat = (AteMetrics.hit - height) / 2
}
