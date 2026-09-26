import SwiftUI

/// **The design's shadows, as the artboards write them.**
///
/// `design/v1` uses CSS `box-shadow` with a *negative spread* on every one of them — the shape is
/// shrunk before it is blurred, which is what makes these reads tight and close rather than the soft
/// halo a plain `.shadow(radius:)` gives. SwiftUI has no spread, so the shadow is cast by a shrunken
/// copy of the same shape drawn *behind* the real one: the copy is smaller than what covers it, so
/// only its blur escapes.
///
/// `blur` is the CSS value; SwiftUI's radius is half of it.
struct AteShadow: Equatable, Sendable {
    var colour: Color
    var offsetY: CGFloat
    var blur: CGFloat
    var spread: CGFloat

    /// The composer's star popover: `0 18px 40px -18px rgba(36,20,31,.45)` (its 1.5px ink ring is a
    /// stroke, drawn by the panel itself).
    static let panel = AteShadow(colour: AteColor.ink.opacity(0.45), offsetY: 18, blur: 40, spread: -18)
}

extension View {
    /// Fills `shape` behind this view and casts `shadow` from it, spread and all.
    func ateBackground(_ fill: Color, in shape: some InsettableShape, shadow: AteShadow) -> some View {
        background {
            ZStack {
                shape
                    .inset(by: -shadow.spread)
                    .fill(fill)
                    .shadow(color: shadow.colour, radius: shadow.blur / 2, x: 0, y: shadow.offsetY)
                shape.fill(fill)
            }
        }
    }
}
