import CoreGraphics
import Testing
@testable import AteKit

/// The share card's Adjust: the automatic crop, the whole photo, and the edges.
@Suite("Photo framing")
struct PhotoFramingTests {
    /// A square photo in a 9:16 story frame.
    private let square = CGSize(width: 1000, height: 1000)
    private let story = CGSize(width: 360, height: 640)

    @Test func theAutomaticCropFillsTheFrame() {
        let drawn = PhotoFraming.automatic.drawnSize(image: square, frame: story)
        #expect(drawn.width == 640)
        #expect(drawn.height == 640)
        #expect(PhotoFraming.automatic.isAdjusted == false)
    }

    @Test func zoomingOutStopsAtTheWholePhoto() {
        let minimum = PhotoFraming.minimumZoom(image: square, frame: story)
        #expect(abs(minimum - 360.0 / 640.0) < 0.0001)
        let framing = PhotoFraming(zoom: 0.1).clamped(image: square, frame: story)
        #expect(abs(framing.zoom - minimum) < 0.0001)
        let drawn = framing.drawnSize(image: square, frame: story)
        #expect(abs(drawn.width - 360) < 0.001)
        #expect(framing.isAdjusted)
    }

    @Test func zoomingInStopsAtThreeTimesTheFill() {
        #expect(PhotoFraming(zoom: 9).clamped(image: square, frame: story).zoom == PhotoFraming.maximumZoom)
    }

    @Test func aPhotoCannotBeDraggedPastItsEdge() {
        // At the fill the square is 640 wide in a 360 frame: 140 spare each side, 0.389 of the frame.
        let framing = PhotoFraming(offset: CGSize(width: 2, height: 2)).clamped(image: square, frame: story)
        #expect(abs(framing.offset.width - 140.0 / 360.0) < 0.0001)
        #expect(framing.offset.height == 0)
    }

    @Test func theWholePhotoMovesInsideTheFrame() {
        let minimum = PhotoFraming.minimumZoom(image: square, frame: story)
        let framing = PhotoFraming(offset: CGSize(width: 0, height: -1), zoom: minimum)
            .clamped(image: square, frame: story)
        // 360 tall in a 640 frame: 140 spare above and below.
        #expect(abs(framing.offset.height + 140.0 / 640.0) < 0.0001)
        #expect(framing.offsetPoints(in: story).height < 0)
    }
}
