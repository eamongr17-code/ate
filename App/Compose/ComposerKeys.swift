import SwiftUI

/// A composer toolbar key: **Score** (butter, an accent, so it carries ink) and **Place** (the field
/// colour, so it carries the surface's own foreground).
///
/// The foreground is a parameter for exactly that reason. Hard-wiring ink — which the spike did —
/// made the Place key near-invisible in dark mode: ink text on a plum pill.
struct ComposerKey: View {
    let title: String
    let icon: AteIcon
    /// The artboards size the two keys' icons differently: the Score star is 15, the Place pin 16.
    var iconSize: CGFloat = 15
    let background: Color
    let foreground: Color
    /// Inverted, the way `ComposerStars` draws the Score key while its slider is open: the pill
    /// becomes ink and the lettering becomes the colour the pill used to be.
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.view(size: iconSize)
                Text(title).ateText(.controlSmall)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: AteMetrics.keyHeight)
            .background(isActive ? AtePalette.surface.fg : background, in: .capsule)
            .foregroundStyle(isActive ? background : foreground)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.key.\(title.lowercased())")
    }
}

/// **Done** — the ink pill both composer screens carry in the same corner. One component, so the key
/// that saves the entry looks and behaves the same whether you were typing or talking.
struct ComposerDoneButton: View {
    var isEnabled: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .ateText(.control)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(AtePalette.surface.fg, in: .capsule)
                .foregroundStyle(AtePalette.surface.inverted)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isBusy)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.trailing, AteMetrics.regular)
    }
}
