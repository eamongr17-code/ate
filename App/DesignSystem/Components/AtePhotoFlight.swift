import SwiftUI

/// Where a full-screen photo lands on the tile it came from (24 Oct; the system zoom shrank the
/// whole black screen into the tile). The viewer fits the picture to the screen; the tile fills its
/// square with the picture's middle. So the photo is cropped to the tile's shape, scaled to its
/// size, tilted to its angle and moved onto it, and the same in reverse as it opens.
struct AtePhotoLanding: Equatable {
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
        let aspect = target.width / target.height
        crop = fitted.width / fitted.height > aspect
            ? CGSize(width: fitted.height * aspect, height: fitted.height)
            : CGSize(width: fitted.width, height: fitted.width / aspect)
        scale = target.width / crop.width
        radius = tile.radius / scale
        angle = tile.angle
        offset = CGSize(width: target.midX - screen.width / 2, height: target.midY - screen.height / 2)
    }
}

/// The photo on its way between the screen and its tile: at home it is the tile; away it fills the
/// screen and follows the drag down, shrinking a little as Photos does.
struct AtePhotoFlight: ViewModifier {
    let landing: AtePhotoLanding?
    let isHome: Bool
    let drag: CGFloat

    func body(content: Content) -> some View {
        let home = isHome ? landing : nil
        let away = 1 - min(abs(drag), AtePhotoViewerMetrics.dragShrinkDistance)
            / AtePhotoViewerMetrics.dragShrinkDistance * AtePhotoViewerMetrics.dragShrink
        content
            // One shape throughout, so its size and corners animate rather than swap.
            .mask {
                RoundedRectangle(cornerRadius: home?.radius ?? 0, style: .continuous)
                    .frame(width: home?.crop.width ?? AteScreen.width, height: home?.crop.height ?? AteScreen.height)
            }
            .scaleEffect(home?.scale ?? away)
            .rotationEffect(.degrees(home?.angle ?? 0))
            .offset(home?.offset ?? CGSize(width: 0, height: drag))
    }
}

enum AtePhotoViewerMetrics {
    /// The photo's flight out of its tile and back.
    static let fly: Animation = .spring(duration: 0.36, bounce: 0.1)
    /// A drag down shrinks the photo by up to this much, over this distance.
    static let dragShrink: CGFloat = 0.2
    static let dragShrinkDistance: CGFloat = 400
}
