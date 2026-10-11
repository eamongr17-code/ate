import AteKit
import SwiftUI
import UIKit

/// What the system sheet is handed.
struct ShareSender {
    /// The rendered picture — `Identifiable` so it can present the system sheet.
    struct Sending: Identifiable {
        let id = UUID()
        let image: UIImage
        /// The receipt on a transparent ground, for an Instagram Stories sticker.
        var sticker: UIImage?
        /// What the system sheet is handed instead of the image — a link item, for a list.
        var items: [Any]?
    }
}

/// Turning the photo URLs behind a receipt into something ``ImageRenderer`` can actually draw.
///
/// An `AsyncImage` inside a renderer captures its placeholder, so the two photos are fetched *before*
/// the card is drawn — on screen and in the export alike, which is what makes the two identical.
enum SharePhotos {
    @MainActor
    static func resolve(_ urls: [URL], limit: Int = 2) async -> [AtePhoto] {
        var resolved: [AtePhoto] = []
        for url in urls.prefix(max(1, limit)) {
            guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                // A bundled fixture (`asset://`, `preview://`) — ``AtePhotoContent`` draws those
                // synchronously, so the renderer sees a real picture without a round trip.
                resolved.append(AtePhoto(url: url))
                continue
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { continue }
            resolved.append(AtePhoto(image: Image(uiImage: image)))
        }
        return resolved
    }
}

extension SharePhotos {
    /// The photo the share cards are made from, as pixels: one already in memory (the composer's
    /// staged picks) drawn once, one on the server fetched at full size.
    @MainActor
    static func image(_ photo: AtePhoto?) async -> UIImage? {
        guard let photo else { return nil }
        if let url = photo.url {
            return await AteImagePipeline.shared.image(url, size: .full)
        }
        guard let image = photo.image else { return nil }
        let renderer = ImageRenderer(content: image)
        renderer.scale = 1
        return renderer.uiImage
    }

    /// The entry's first photo, from its address.
    @MainActor
    static func image(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await AteImagePipeline.shared.image(url, size: .full)
    }
}
