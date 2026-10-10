import UIKit

/// An avatar, drawn down from whatever the library gave — Settings → Photo and first run's photo
/// step. 512 on the long side, JPEG: the largest an avatar is ever shown is 176pt, on first run.
enum AvatarImage {
    static let pixels: CGFloat = 512
    static let quality: CGFloat = 0.85

    static func jpeg(from image: UIImage) -> Data? {
        let scale = min(1, pixels / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: quality)
    }
}
