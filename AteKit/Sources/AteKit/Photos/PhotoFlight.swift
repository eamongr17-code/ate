import CoreGraphics

/// **Where a full-screen photo is, on its way between its tile and the screen** (24 Oct, rebuild).
/// The viewer flies one picture inside one rounded frame. At home the frame *is* the tile (its
/// square, its corners, its tilt) and the picture sits in it exactly as the tile crops it; at rest
/// the frame is the whole picture fitted to the page, exactly where the pager draws it. The whole
/// flight is ``between(_:_:progress:)`` of those two, for one number running 0 → 1 (open) or
/// 1 → 0 (close), so the first and last frames are the tile and the page to the point, and nothing
/// is corrected after it lands.
public enum PhotoFlight {
    public struct Frame: Equatable, Sendable {
        /// In window coordinates.
        public var center: CGPoint
        public var size: CGSize
        public var radius: CGFloat
        /// Degrees.
        public var angle: Double
        /// The whole picture, in the frame's own untilted space (origin at its top-left): larger
        /// than the frame where the frame crops it, the frame itself at rest.
        public var picture: CGRect

        public init(center: CGPoint, size: CGSize, radius: CGFloat, angle: Double, picture: CGRect? = nil) {
            self.center = center
            self.size = size
            self.radius = radius
            self.angle = angle
            self.picture = picture ?? CGRect(origin: .zero, size: size)
        }

        public var rect: CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height)
        }
    }

    /// A drag down shrinks the photo by up to this much, over this distance, as Photos does.
    public static let dragShrink: CGFloat = 0.2
    public static let dragShrinkDistance: CGFloat = 400

    /// On the tile: its own frame, corners and tilt, with the picture of `image`'s shape cropped as
    /// the tile crops it: `crop` (the part of the picture that fills the tile, in the picture's
    /// units: a dish page's focus), else the middle, as a fill does.
    public static func home(tile: CGRect, radius: CGFloat, angle: Double, image: CGSize, crop: CGRect? = nil) -> Frame {
        let shown = crop ?? fill(image: image, aspect: tile.height > 0 ? tile.width / tile.height : 1)
        let scale = shown.width > 0 ? tile.width / shown.width : 1
        let picture = image.width > 0 && image.height > 0
            ? CGRect(x: -shown.minX * scale, y: -shown.minY * scale,
                     width: image.width * scale, height: image.height * scale)
            : CGRect(origin: .zero, size: tile.size)
        return Frame(center: CGPoint(x: tile.midX, y: tile.midY), size: tile.size, radius: radius, angle: angle,
                     picture: picture)
    }

    /// The middle of a picture of `image`'s shape that a frame of `aspect` (width over height) shows
    /// when the picture fills it.
    public static func fill(image: CGSize, aspect: CGFloat) -> CGRect {
        guard image.width > 0, image.height > 0, aspect > 0 else { return CGRect(origin: .zero, size: image) }
        if image.width / image.height > aspect {
            let width = image.height * aspect
            return CGRect(x: (image.width - width) / 2, y: 0, width: width, height: image.height)
        }
        let height = image.width / aspect
        return CGRect(x: 0, y: (image.height - height) / 2, width: image.width, height: height)
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

    /// The flight a fraction `progress` of the way from `from` to `to`: the one thing the flying
    /// picture draws, every frame (the timing curve only changes how fast `progress` moves).
    public static func between(_ from: Frame, _ to: Frame, progress: CGFloat) -> Frame {
        // Weighted, so 0 and 1 are the two ends exactly, not a sum that rounds off them.
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * (1 - progress) + b * progress }
        return Frame(
            center: CGPoint(x: mix(from.center.x, to.center.x), y: mix(from.center.y, to.center.y)),
            size: CGSize(width: mix(from.size.width, to.size.width), height: mix(from.size.height, to.size.height)),
            radius: mix(from.radius, to.radius),
            angle: from.angle * Double(1 - progress) + to.angle * Double(progress),
            picture: CGRect(
                x: mix(from.picture.minX, to.picture.minX), y: mix(from.picture.minY, to.picture.minY),
                width: mix(from.picture.width, to.picture.width), height: mix(from.picture.height, to.picture.height)
            )
        )
    }

    /// The tiles stacked over `flying` that the flight has to draw over it as it leaves and lands,
    /// bottom first, as `(key, layer)` pairs — `tiles` is every tile of the cluster, layer 0 on top.
    /// One reaching the flying tile (`reach`, a tilt's corner past the square) is a cover, and so is
    /// any tile above a cover that laps over it: drawn alone, a cover lands on top of the photos the
    /// page draws over it (26 Oct: the third photo opened and the middle one jumped to the front).
    public static func covers<Key: Hashable>(
        over flying: Key, tiles: [Key: (frame: CGRect, layer: Int)], reach: CGFloat = 0.2
    ) -> [Key] {
        guard let home = tiles[flying] else { return [] }
        func grown(_ frame: CGRect) -> CGRect { frame.insetBy(dx: -frame.width * reach, dy: -frame.height * reach) }
        var found: [Key: Int] = [:]
        var reaching = [(frame: grown(home.frame), layer: home.layer)]
        while let under = reaching.popLast() {
            for (key, tile) in tiles where found[key] == nil && tile.layer < under.layer
                && tile.frame.intersects(under.frame) {
                found[key] = tile.layer
                reaching.append((grown(tile.frame), tile.layer))
            }
        }
        return found.sorted { $0.value > $1.value }.map(\.key)
    }

    /// A tile partly off the screen would be landed on whole and then pop to its clipped self, so
    /// such a photo fades instead.
    public static func canLand(on tile: CGRect, screen: CGSize) -> Bool {
        tile.width > 0 && tile.height > 0 && CGRect(origin: .zero, size: screen).contains(tile)
    }
}
