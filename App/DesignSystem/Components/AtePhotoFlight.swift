import SwiftUI

/// Where a full-screen photo lands on the tile it came from (24 Oct; the system zoom shrank the
/// whole black screen into the tile). The viewer fits the picture to the screen; the tile fills its
/// square with the picture's middle. So the photo is cropped to the tile's shape, scaled to its
/// size, tilted to its angle and moved onto it, and the same in reverse as it opens.
struct AtePhotoLanding: Equatable {
    /// The whole picture, fitted to the screen and centred on it.
    let fitted: CGSize
    /// The part of the screen-fitted picture the tile shows, centred on the screen.
    let crop: CGSize
    let scale: CGFloat
    /// The tile's corners, before the scale.
    let radius: CGFloat
    let angle: Double
    /// From the screen's centre to the tile's.
    let offset: CGSize

    init?(tile: AtePhotoOrigin.Tile, image: CGSize, screen: CGSize) {
        let target = tile.frame
        guard image.width > 0, image.height > 0, target.width > 0, target.height > 0,
              screen.width > 0, screen.height > 0 else { return nil }
        let fit = min(screen.width / image.width, screen.height / image.height)
        let fitted = CGSize(width: image.width * fit, height: image.height * fit)
        self.fitted = fitted
        let aspect = target.width / target.height
        crop = fitted.width / fitted.height > aspect
            ? CGSize(width: fitted.height * aspect, height: fitted.height)
            : CGSize(width: fitted.width, height: fitted.width / aspect)
        scale = target.width / crop.width
        radius = tile.radius / scale
        angle = tile.angle
        offset = CGSize(width: target.midX - screen.width / 2, height: target.midY - screen.height / 2)
        // A tile partly off the screen would be landed on whole and then pop to its clipped self.
        guard CGRect(origin: .zero, size: screen).contains(target) else { return nil }
    }
}

/// One page's picture cropped for the flight: the tile's crop at home, the whole picture away
/// (24 Oct, build 194: masked from the whole screen, the uncropped photo hung on and squared off
/// only at the very end). Per page, so paging to a photo of another shape is never clipped; the
/// screen when zoomed in, so nothing zoomed is either.
struct AtePhotoCrop: ViewModifier {
    let landing: AtePhotoLanding?
    let isHome: Bool
    let isZoomed: Bool

    func body(content: Content) -> some View {
        let home = isHome ? landing : nil
        let shape = home?.crop ?? (isZoomed ? nil : landing?.fitted) ?? AteScreen.size
        content
            // One shape throughout, so its size and corners animate rather than swap.
            .mask {
                RoundedRectangle(cornerRadius: home?.radius ?? 0, style: .continuous)
                    .frame(width: shape.width, height: shape.height)
            }
    }
}

/// The photo on its way between the screen and its tile: at home it sits on the tile; away it fills
/// the screen and follows the drag down, shrinking a little as Photos does.
struct AtePhotoFlight: ViewModifier {
    let landing: AtePhotoLanding?
    let isHome: Bool
    let drag: CGFloat

    func body(content: Content) -> some View {
        let home = isHome ? landing : nil
        let away = 1 - min(abs(drag), AtePhotoViewerMetrics.dragShrinkDistance)
            / AtePhotoViewerMetrics.dragShrinkDistance * AtePhotoViewerMetrics.dragShrink
        content
            .scaleEffect(home?.scale ?? away)
            .rotationEffect(.degrees(home?.angle ?? 0))
            .offset(home?.offset ?? CGSize(width: 0, height: drag))
    }
}

enum AtePhotoViewerMetrics {
    /// The photo's flight out of its tile and back.
    /// No bounce: an overshoot of a small tile spills over the text round it.
    static let fly: Animation = .smooth(duration: 0.4)
    /// A drag down shrinks the photo by up to this much, over this distance.
    static let dragShrink: CGFloat = 0.2
    static let dragShrinkDistance: CGFloat = 400
}
