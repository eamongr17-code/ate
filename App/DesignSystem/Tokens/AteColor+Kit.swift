import SwiftUI

/// **The component kit's colours** (rebuild phase 2a) — the few the kit needs that the palette does
/// not already carry as a role. Read by `App/DesignSystem/Kit/` only; a screen never names them.
enum AteKitColor {
    /// The hero's shade, top and foot — `linear-gradient(180deg, rgba(36,20,31,0) 30%,
    /// rgba(36,20,31,.82))`. Ink in both modes: it darkens a photo, not the page.
    static let heroShadeTop = AteColor.ink.opacity(0)
    static let heroShadeFoot = AteColor.ink.opacity(0.82)
    /// Where the shade starts to fall.
    static let heroShadeStart: CGFloat = 0.3
    /// Words over the hero's shade — white, and the place at `opacity:.85`.
    static let overPhoto = Color.white
    static let overPhotoMuted = Color.white.opacity(0.85)
    /// The count on a glass control's badge (the Journal's photos): coral, ink on it.
    static let badge = AteColor.coral
    static let badgeInk = AteColor.ink
    /// A filter chip's ✕, a touch under the chip's lettering (`.chip i{opacity:.75}`).
    static let chipClearOpacity: Double = 0.75
    /// The off state every disabled control shares: a muted tick (`.tick.off{opacity:.4}`) and an
    /// ink pill waiting on its thing.
    static let disabledOpacity: Double = 0.4
}
