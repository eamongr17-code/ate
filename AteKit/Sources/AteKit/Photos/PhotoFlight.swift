import CoreGraphics

/// **Where a full-screen photo is, on its way between its tile and the screen** (24 Oct, round 4).
/// The viewer flies one picture, filled into a rounded frame: at home that frame *is* the tile
/// (its square, its corners, its tilt), so the picture is cropped exactly as the tile crops it;
/// at rest it is the whole picture fitted to the page. Animating between the two frames is the
/// whole flight. The frame is the crop, so there is no mask that can fail to apply (builds 194–196:
/// a SwiftUI mask over the UIKit pager did nothing on a phone).
public enum PhotoFlight {
    public struct Frame: Equatable, Sendable {
        /// In window coordinates.
        public var center: CGPoint
        public var size: CGSize
        public var radius: CGFloat
        /// Degrees.
        public var angle: Double

        public init(center: CGPoint, size: CGSize, radius: CGFloat, angle: Double) {
            self.center = center
            self.size = size
            self.radius = radius
            self.angle = angle
        }

        public var rect: CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height)
        }
    }

    /// A drag down shrinks the photo by up to this much, over this distance, as Photos does.
    public static let dragShrink: CGFloat = 0.2
    public static let dragShrinkDistance: CGFloat = 400

    /// On the tile: its own frame, corners and tilt.
    public static func home(tile: CGRect, radius: CGFloat, angle: Double) -> Frame {
        Frame(center: CGPoint(x: tile.midX, y: tile.midY), size: tile.size, radius: radius, angle: angle)
    }

    /// How much a drag of `drag` points has shrunk the photo.
    public static func scale(drag: CGFloat) -> CGFloat {
        1 - min(abs(drag), dragShrinkDistance) / dragShrinkDistance * dragShrink
    }

    /// The whole picture fitted into the page, as the pager draws it; dragged `drag` down, shrunk
    /// about `anchor` (the pager's centre) as the pager is. `nil` without a picture shape or a page.
    public static func away(image: CGSize, page: CGRect, anchor: CGPoint, drag: CGFloat = 0) -> Frame? {
        guard image.width > 0, image.height > 0, page.width > 0, page.height > 0 else { return nil }
        let fit = min(page.width / image.width, page.height / image.height)
        let scale = scale(drag: drag)
        let center = CGPoint(
            x: anchor.x + (page.midX - anchor.x) * scale,
            y: anchor.y + (page.midY - anchor.y) * scale + drag
        )
        return Frame(
            center: center,
            size: CGSize(width: image.width * fit * scale, height: image.height * fit * scale),
            radius: 0,
            angle: 0
        )
    }

    /// The flight a fraction `progress` of the way from `from` to `to` — what an animation of the
    /// frame draws along the way (the timing curve only changes how fast `progress` moves).
    public static func between(_ from: Frame, _ to: Frame, progress: CGFloat) -> Frame {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return Frame(
            center: CGPoint(x: mix(from.center.x, to.center.x), y: mix(from.center.y, to.center.y)),
            size: CGSize(width: mix(from.size.width, to.size.width), height: mix(from.size.height, to.size.height)),
            radius: mix(from.radius, to.radius),
            angle: from.angle + (to.angle - from.angle) * Double(progress)
        )
    }

    /// A tile partly off the screen would be landed on whole and then pop to its clipped self, so
    /// such a photo fades instead.
    public static func canLand(on tile: CGRect, screen: CGSize) -> Bool {
        tile.width > 0 && tile.height > 0 && CGRect(origin: .zero, size: screen).contains(tile)
    }
}
