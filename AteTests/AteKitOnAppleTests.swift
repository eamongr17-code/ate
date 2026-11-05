import AteKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// **AteKit's Apple-only paths.** AteKit's own suite runs on Linux (CI's Linux job and
/// `scripts/test-linux.sh`), where ImageIO and NSDataDetector don't exist and those paths are
/// fenced off. These run them on the simulator instead, in the snapshot step that boots it anyway.
final class AteKitOnAppleTests: XCTestCase {
    func testThumbnailIsAJPEGAt480OnTheLongSide() throws {
        let jpeg = try XCTUnwrap(PhotoThumbnail.jpeg(from: Self.jpeg(width: 1600, height: 1200)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 480)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 360)
    }

    func testNotAnImageHasNoThumbnail() {
        XCTAssertNil(PhotoThumbnail.jpeg(from: Data("not a photo".utf8)))
    }

    /// The link detector's path (Linux reads words instead): same answers as ShareInTests.
    func testFirstHTTPSLinkInTextWithoutItsPunctuation() {
        XCTAssertEqual(
            SharedLink.find(in: "Look at this! https://vm.tiktok.com/ZMabc/.")?.absoluteString,
            "https://vm.tiktok.com/ZMabc/"
        )
        XCTAssertEqual(
            SharedLink.find(in: "http://insecure.example/x and https://www.instagram.com/reel/C1/")?.absoluteString,
            "https://www.instagram.com/reel/C1/"
        )
        XCTAssertNil(SharedLink.find(in: "no link here"))
    }

    private static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let image = try XCTUnwrap(context.makeImage())
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
