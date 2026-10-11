import CoreGraphics

/// **Where a photo sits in a share card's frame** (11 Oct, Eamon: "Adjust should allow use of the full
/// photo"). The automatic crop fills the frame (zoom 1); pinching out can go as far as the whole
/// photo fitting inside it, and in to three times the fill. The offset is a fraction of the frame,
/// so the same framing draws the same picture on the small card on screen and the 1080-wide export.
public struct PhotoFraming: Equatable, Sendable {
    /// How far the photo's centre is moved from the frame's centre, as a fraction of the frame.
    public var offset: CGSize
    /// 1 is the automatic crop: the photo just filling the frame.
    public var zoom: CGFloat

    public static let automatic = PhotoFraming(offset: .zero, zoom: 1)
    /// The closest a photo can be pushed in, against the fill.
    public static let maximumZoom: CGFloat = 3

    public init(offset: CGSize = .zero, zoom: CGFloat = 1) {
        self.offset = offset
        self.zoom = zoom
    }

    /// Moved or zoomed off the automatic crop.
    public var isAdjusted: Bool {
        abs(offset.width) > 0.001 || abs(offset.height) > 0.001 || abs(zoom - 1) > 0.001
    }

    /// The zoom at which the whole photo fits inside the frame: 1 or less.
    public static func minimumZoom(image: CGSize, frame: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return 1 }
        return fitScale(image: image, frame: frame) / coverScale(image: image, frame: frame)
    }

    /// The photo's drawn size in the frame, at this zoom.
    public func drawnSize(image: CGSize, frame: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return frame }
        let scale = Self.coverScale(image: image, frame: frame) * zoom
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The offset in the frame's own points.
    public func offsetPoints(in frame: CGSize) -> CGSize {
        CGSize(width: offset.width * frame.width, height: offset.height * frame.height)
    }

    /// Held inside what the photo allows: the zoom between the whole photo and three times the fill,
    /// and the photo never dragged further than its edge (when it is larger than the frame) or the
    /// frame's edge (when the whole photo is smaller).
    public func clamped(image: CGSize, frame: CGSize) -> PhotoFraming {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return self }
        var framing = self
        framing.zoom = min(Self.maximumZoom, max(Self.minimumZoom(image: image, frame: frame), zoom))
        let drawn = framing.drawnSize(image: image, frame: frame)
        let reachX = abs(drawn.width - frame.width) / 2 / frame.width
        let reachY = abs(drawn.height - frame.height) / 2 / frame.height
        framing.offset = CGSize(
            width: min(reachX, max(-reachX, offset.width)),
            height: min(reachY, max(-reachY, offset.height))
        )
        return framing
    }

    private static func coverScale(image: CGSize, frame: CGSize) -> CGFloat {
        max(frame.width / image.width, frame.height / image.height)
    }

    private static func fitScale(image: CGSize, frame: CGSize) -> CGFloat {
        min(frame.width / image.width, frame.height / image.height)
    }
}
