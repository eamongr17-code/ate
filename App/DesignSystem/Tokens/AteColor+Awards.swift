import SwiftUI

/// **Plate awards' colours** (`design/rebuild/plate-awards-screens.html`, approved 28 Oct). Read by
/// the awards kit and its screens only.
enum AteAwardColor {
    /// The takeover's ground: ink in both modes, lit from behind the plate —
    /// `radial-gradient(90% 46% at 50% 31%, #3A2C3F, #17111B 72%)`.
    static let takeoverGlow = Color(hex: 0x3A2C3F)
    static let takeoverGround = Color(hex: 0x17111B)
    /// Where the glow sits and how far it reaches, as fractions of the screen.
    static let takeoverGlowCentre = UnitPoint(x: 0.5, y: 0.31)
    static let takeoverGlowStop: CGFloat = 0.72
    /// The takeover's words: cream, and the date muted.
    static let takeoverInk = Color(hex: 0xF4EFE9)
    static let takeoverMuted = Color(hex: 0xB9AFBC)
    /// Its page dots: the current one cream, the rest white at 28%.
    static let takeoverDot = Color.white.opacity(0.28)
    /// The quiet pill beside Share — white at 12% on the ink, a hairline of white at 20%.
    static let takeoverQuietPill = Color.white.opacity(0.12)
    static let takeoverQuietEdge = Color.white.opacity(0.2)
    /// An award not earned yet: a silhouette in the plate's shape, a step off the ground.
    static let silhouette = Color(light: Color(hex: 0xCDC4B7), dark: Color(hex: 0x30273A))
}
