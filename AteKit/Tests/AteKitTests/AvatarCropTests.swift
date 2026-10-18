import AteKit
import CoreGraphics
import Testing

@Suite("Avatar crop — the photo always covers the circle")
struct AvatarCropTests {
    /// A portrait photo, 900 × 1200, in a 300pt circle: the fill is a third.
    private let crop = AvatarCrop(image: CGSize(width: 900, height: 1200), diameter: 300)

    @Test("starts filling the circle, centred")
    func starts() {
        #expect(crop.scale == 300.0 / 900.0)
        #expect(abs(crop.origin.x) < 0.001 && abs(crop.origin.y + 50) < 0.001)
        #expect(close(crop.cropRect, CGRect(x: 0, y: 150, width: 900, height: 900)))
    }

    @Test("can't zoom out past the fill, or in past five times it")
    func zoomLimits() {
        #expect(crop.adjusted(zoom: 0.2).scale == crop.minimumScale)
        #expect(crop.adjusted(zoom: 50).scale == crop.minimumScale * AvatarCrop.maximumZoom)
    }

    @Test("can't drag a gap into the circle")
    func panLimits() {
        let dragged = crop.adjusted(pan: CGSize(width: 500, height: -500))
        #expect(abs(dragged.origin.x) < 0.001 && abs(dragged.origin.y + 100) < 0.001)
        #expect(close(dragged.cropRect, CGRect(x: 0, y: 300, width: 900, height: 900)))
    }

    @Test("zooming keeps the circle's centre on the same spot of the photo")
    func zoomsAroundCentre() {
        let zoomed = crop.adjusted(zoom: 2)
        #expect(abs(zoomed.cropRect.midX - crop.cropRect.midX) < 0.001)
        #expect(abs(zoomed.cropRect.midY - crop.cropRect.midY) < 0.001)
        #expect(abs(zoomed.cropRect.width - 450) < 0.001)
    }

    private func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.001 && abs(lhs.minY - rhs.minY) < 0.001
            && abs(lhs.width - rhs.width) < 0.001 && abs(lhs.height - rhs.height) < 0.001
    }
}
