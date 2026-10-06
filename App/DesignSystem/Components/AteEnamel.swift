import SwiftUI

/// **Enamel** — the score pill's depth (Eamon's pick of four, 2026-10-06): a hairline of light along
/// the top edge and a hairline of shade along the bottom, both drawn *inside* the capsule, so the
/// pill reads like an enamel badge without growing, casting a shadow or looking like a button.
///
/// Inside, not a drop shadow: prose pills are rasterised to their exact bounds (``TokenPill``), and
/// anything drawn outside the capsule would be clipped there and nowhere else. One stroke, the same
/// on every pill that prints a score.
private struct Enamel: ViewModifier {
    /// The pill's fill is light (butter) — a brighter top and a softer bottom read as depth; on the
    /// brick 6 the light is halved so it doesn't wash the red pink.
    let onDarkFill: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay {
            Capsule().strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(light), location: 0),
                        .init(color: .white.opacity(0), location: 0.45),
                        .init(color: shadeColor.opacity(0), location: 0.55),
                        .init(color: shadeColor.opacity(shade), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
    }

    private var isDark: Bool { colorScheme == .dark }
    private var light: Double { onDarkFill ? 0.28 : (isDark ? 0.38 : 0.6) }
    private var shade: Double { isDark || onDarkFill ? 0.24 : 0.16 }
    private var shadeColor: Color { isDark ? .black : AteColor.ink }
}

extension View {
    /// The score pill's enamel edge. See ``Enamel``.
    func ateEnamel(onDarkFill: Bool = false) -> some View {
        modifier(Enamel(onDarkFill: onDarkFill))
    }
}
