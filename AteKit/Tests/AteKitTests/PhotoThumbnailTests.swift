import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AteKit

@Suite("Photo thumbnails")
struct PhotoThumbnailTests {
    @Test("the small copy sits beside the full one, named _t.jpg")
    func path() {
        #expect(PhotoThumbnail.path(for: "u/e-0.jpg") == "u/e-0_t.jpg")
        #expect(PhotoThumbnail.path(for: "u/e-2-ab12.jpeg") == "u/e-2-ab12_t.jpg")
        #expect(PhotoThumbnail.path(for: "u.v/e") == "u.v/e_t.jpg")
    }

    @Test("max 480 on the long side, and a JPEG")
    func size() throws {
        let jpeg = try #require(PhotoThumbnail.jpeg(from: Self.jpeg(width: 1600, height: 1200)))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 480)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 360)
    }

    @Test("not an image, no thumbnail")
    func garbage() {
        #expect(PhotoThumbnail.jpeg(from: Data("not a photo".utf8)) == nil)
    }

    @Test("a public URL maps back to its storage path")
    func storagePath() {
        let url = "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-0.jpg"
        #expect(SupabaseEntryService.storagePath(fromPublicURL: url) == "u/e-0.jpg")
        #expect(SupabaseEntryService.storagePath(fromPublicURL: "preview://e/0") == nil)
    }

    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
