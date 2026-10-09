import SwiftUI

/// **Glass pills** — the score pill and the diet chip in the app's Liquid Glass (Eamon, 9 Oct: the
/// enamel badge clashed with the glass around it). They keep their **filled colours**: butter (or
/// brick for a 6) for a score, the muted ground for a diet chip.
///
/// Two drawings of one look, because there are two kinds of pill:
/// - **Live pills** (a dish row's score, the hero's, a dish's codes beside its name) are iOS 26's own
///   glass, tinted with the fill — ``SwiftUI/View/ateGlassPill(_:in:)``.
/// - **Pills in the words** are rasterised into a text view's attachments (``TokenPill``), and real
///   glass cannot sample what is behind an image. They carry the glass's light instead — a bright
///   rim along the top and a soft sheen over the upper half, drawn *inside* the shape so nothing is
///   clipped at the image's bounds — ``SwiftUI/View/ateGlassSheen(onDarkFill:rim:in:)``.
private struct GlassSheen<S: InsettableShape>: ViewModifier {
    /// On the brick 6 the light is halved so it doesn't wash the red pink.
    let onDarkFill: Bool
    let shape: S
    /// The bright rim. Off for a diet code that runs on into its neighbour, where the rim's sides
    /// would draw a seam through the middle of one chip.
    let rim: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(sheen), location: 0),
                            .init(color: .white.opacity(0), location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                if rim {
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(rimLight), location: 0),
                                .init(color: .white.opacity(rimLight * 0.25), location: 0.5),
                                .init(color: .white.opacity(rimLight * 0.5), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var isDark: Bool { colorScheme == .dark }
    private var rimLight: Double { onDarkFill ? 0.35 : (isDark ? 0.4 : 0.75) }
    private var sheen: Double { onDarkFill ? 0.12 : (isDark ? 0.14 : 0.3) }
}

extension View {
    /// A pill in the words: its fill, with the glass's light drawn on. See ``GlassSheen``.
    func ateGlassSheen<S: InsettableShape>(
        onDarkFill: Bool = false, rim: Bool = true, in shape: S
    ) -> some View {
        modifier(GlassSheen(onDarkFill: onDarkFill, shape: shape, rim: rim))
    }

    /// A pill in the words, capsule-shaped.
    func ateGlassSheen(onDarkFill: Bool = false) -> some View {
        ateGlassSheen(onDarkFill: onDarkFill, in: Capsule())
    }

    /// A live pill: Liquid Glass tinted with the pill's own fill, so it stays a filled colour.
    func ateGlassPill<S: Shape>(_ tint: Color, in shape: S) -> some View {
        glassEffect(.regular.tint(tint), in: shape)
    }
}
