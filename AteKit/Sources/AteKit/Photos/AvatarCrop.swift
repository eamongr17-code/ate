import CoreGraphics

/// **Where a photo sits in the avatar's circle** (Settings → Photo and first run's photo step,
/// `design/rebuild/settings-photo-crop.html`, option A, 18 Oct). The photo always covers the circle:
/// never smaller than the fill, never moved far enough to leave a gap, and in to five times the fill.
/// Geometry only, in the circle's own points — the view draws it, ``cropRect`` cuts it.
public struct AvatarCrop: Equatable, Sendable {
    /// The photo's own size, in pixels.
    public let image: CGSize
    /// The circle across, in points.
    public let diameter: CGFloat
    /// Points on screen per pixel of the photo.
    public private(set) var scale: CGFloat
    /// The photo's top-left corner, from the circle's top-left corner, in points (zero or less).
    public private(set) var origin: CGPoint

    /// The closest a photo can be pushed in, against the fill.
    public static let maximumZoom: CGFloat = 5

    /// The photo just filling the circle, centred.
    public init(image: CGSize, diameter: CGFloat) {
        self.image = image
        self.diameter = diameter
        let fill = Self.fillScale(image: image, diameter: diameter)
        scale = fill
        origin = CGPoint(x: (diameter - image.width * fill) / 2, y: (diameter - image.height * fill) / 2)
    }

    /// The smallest scale at which the photo still covers the circle.
    public var minimumScale: CGFloat { Self.fillScale(image: image, diameter: diameter) }

    /// The photo as drawn, in points.
    public var drawnSize: CGSize { CGSize(width: image.width * scale, height: image.height * scale) }

    /// This crop moved by `pan` and zoomed by `zoom` around the circle's centre — what a drag and a
    /// pinch, measured from where they started, make of it. Always covers the circle.
    public func adjusted(pan: CGSize = .zero, zoom: CGFloat = 1) -> AvatarCrop {
        var next = self
        let fill = minimumScale
        let zoomed = min(max(scale * zoom, fill), fill * Self.maximumZoom)
        let ratio = scale > 0 ? zoomed / scale : 1
        let centre = diameter / 2
        next.scale = zoomed
        next.origin = CGPoint(
            x: centre - (centre - origin.x) * ratio + pan.width,
            y: centre - (centre - origin.y) * ratio + pan.height
        )
        next.clamp()
        return next
    }

    /// What is inside the circle, in the photo's pixels: a square.
    public var cropRect: CGRect {
        guard scale > 0 else { return .zero }
        return CGRect(x: -origin.x / scale, y: -origin.y / scale, width: diameter / scale, height: diameter / scale)
    }

    private mutating func clamp() {
        let size = drawnSize
        origin.x = min(0, max(diameter - size.width, origin.x))
        origin.y = min(0, max(diameter - size.height, origin.y))
    }

    private static func fillScale(image: CGSize, diameter: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return diameter / min(image.width, image.height)
    }
}
