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
    /// A list's cover at the head of its page (`lists-playlists.html` `.cov.lift`):
    /// `0 14px 34px rgba(36,20,31,.22)`.
    static let cover = AteShadow(colour: AteColor.ink.opacity(0.22), offsetY: 14, blur: 34, spread: 0)
    /// The photo printed on an accent story.
    /// Onboarding's pictures lifted off the ground (`onboarding-calm.html` `.paper`):
    /// `0 14px 34px rgba(36,20,31,.12)`.
    static let lift = AteShadow(colour: AteColor.ink.opacity(0.12), offsetY: 14, blur: 34, spread: 0)
    static let print = AteShadow(colour: AteColor.ink.opacity(0.35), offsetY: 8, blur: 24, spread: 0)
    /// A share card lifted off the ink sheet.
    static let shareCard = AteShadow(colour: Color.black.opacity(0.45), offsetY: 10, blur: 32, spread: 0)
    /// The sticker card's receipt on the ink sheet.
    static let shareSticker = AteShadow(colour: Color.black.opacity(0.4), offsetY: 10, blur: 28, spread: 0)
    /// The share card's Saved tick — `.tick`: `0 6px 16px rgba(36,20,31,.25)`.
    static let tick = AteShadow(colour: AteColor.ink.opacity(0.25), offsetY: 6, blur: 16, spread: 0)
    /// No shadow: the same background, casting nothing.
    static let flat = AteShadow(colour: .clear, offsetY: 0, blur: 0, spread: 0)
}

extension View {
    /// Casts `shadow` from this view's own pixels (a photo, a whole receipt), for shadows with no
    /// spread. Flattened first: a bare `.shadow` on a stack casts one per layer, so every pill and word
    /// on a receipt smudged its own shadow onto the paper (the share sheet's sticker, 18 Oct).
    func ateShadow(_ shadow: AteShadow) -> some View {
        compositingGroup()
            .shadow(color: shadow.colour, radius: shadow.blur / 2, x: 0, y: shadow.offsetY)
    }

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
