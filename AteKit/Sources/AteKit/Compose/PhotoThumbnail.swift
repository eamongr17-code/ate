import Foundation
import ImageIO
import UniformTypeIdentifiers

/// **The small copy of every uploaded photo** — max 480 on the long side, JPEG q0.8, stored beside
/// the full one at `<same path minus extension>_t.jpg`. Lists draw thumbnails from that path; the
/// full image is for the entry page and the share card.
///
/// ImageIO rather than UIKit so it is the same code on the phone and under `swift test`.
public enum PhotoThumbnail {
    public static let maximumPixelSize = 480
    public static let compressionQuality = 0.8
    /// `user/entry-0.jpg` → `user/entry-0_t.jpg` — ``PhotoAddress``'s rule, the one the lists read
    /// by, so where a thumbnail is written and where it is looked for cannot drift.
    public static func path(for original: String) -> String {
        PhotoAddress.thumbnailPath(for: original) ?? original
    }

    /// The thumbnail's JPEG bytes, or `nil` when the data is not an image ImageIO can read.
    public static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
