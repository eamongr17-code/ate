import UIKit

/// An avatar, drawn down from whatever the library gave — Settings → Photo and first run's photo
/// step. 512 across at most, JPEG: the largest an avatar is ever shown is 176pt, on first run.
enum AvatarImage {
    static let pixels: CGFloat = 512
    static let quality: CGFloat = 0.85

    /// Just the square inside the circle (``AteAvatarCropper``), in the photo's own points, drawn
    /// down to at most 512 across.
    static func jpeg(from image: UIImage, cropping square: CGRect) -> Data? {
        guard square.width > 0 else { return nil }
        let side = min(pixels, square.width).rounded()
        let scale = side / square.width
        return draw(size: CGSize(width: side, height: side)) {
            image.draw(in: CGRect(
                x: -square.minX * scale,
                y: -square.minY * scale,
                width: image.size.width * scale,
                height: image.size.height * scale
            ))
        }
    }

    private static func draw(size: CGSize, _ drawing: () -> Void) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in drawing() }
        return drawn.jpegData(compressionQuality: quality)
    }
}
