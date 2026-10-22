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
    /// A diet code another pick covers (Vegan → Vegetarian, Dairy free): lit but faded and locked —
    /// the first-run chip at `.pk.implied{opacity:.45}`, a Settings row's name at `rgba(fg,.5)` with
    /// its tick at `.4` (``disabledOpacity``).
    static let coveredChipOpacity: Double = 0.45
    static let coveredRowOpacity: Double = 0.5
    /// What dims the other app under the share card — `.dim{background:rgba(0,0,0,.35)}`.
    static let shareScrim = Color.black.opacity(0.35)
    /// Over the photo outside the avatar's circle while it is positioned — black at 60%.
    static let cropScrim = AteColor.viewerGround.opacity(0.6)
    /// The avatar circle's hairline edge over the photo.
    static let cropRing = AteColor.overPhoto.opacity(0.9)
    /// A dish's name over its photo — an ink capsule at 78%, so the food shows at its edge
    /// (`.tag{background:rgba(20,14,18,.78)}`).
    static let photoDishName = AteColor.ink.opacity(0.78)
    /// The share card's grabber, in the surface's ink — `rgba(36,20,31,.2)`.
    static let grabberOpacity: Double = 0.2
}
