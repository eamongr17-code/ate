import AteKit
import SwiftUI
import UIKit

/// Render, and hand it to the system. **A render that fails is never silent**: it does not open the
/// sheet and does not count as a share; the pill says "Try again" — one word on the control itself,
/// no toast, no banner (design rule 1).
struct ShareSender {
    /// The rendered picture — `Identifiable` so it can present the system sheet.
    struct Sending: Identifiable {
        let id = UUID()
        let image: UIImage
        /// The card on a transparent ground, for an Instagram Stories sticker.
        var sticker: UIImage?
    }

    var sending: Sending?
    var didFail = false

    /// Renders and opens the sheet. The share is counted by the sheet itself, when the picture
    /// actually leaves — and by where it went, so Instagram Stories reads as its own source.
    @MainActor
    mutating func send(artefact: ShareArtefact, photos: [AtePhoto]) {
        guard let image = Self.render(artefact: artefact, photos: photos) else {
            didFail = true
            return
        }
        didFail = false
        sending = Sending(
            image: image,
            sticker: ShareImage.sticker(artefact: artefact, photos: photos)
        )
    }

    @MainActor
    private static func render(artefact: ShareArtefact, photos: [AtePhoto]) -> UIImage? {
        #if DEBUG
        if forcesRenderFailure { return nil }
        #endif
        return ShareImage.render(artefact: artefact, photos: photos)
    }

    #if DEBUG
    /// `-ate-fail-share-render`: the one state that cannot be reached by using the app, made
    /// reachable so it can be driven and looked at like every other.
    static var forcesRenderFailure: Bool {
        DebugLaunch.isOn(.failShareRender)
    }
    #endif
}

/// Turning the photo URLs behind a receipt into something ``ImageRenderer`` can actually draw.
///
/// An `AsyncImage` inside a renderer captures its placeholder, so the two photos are fetched *before*
/// the card is drawn — on screen and in the export alike, which is what makes the two identical.
enum SharePhotos {
    @MainActor
    static func resolve(_ urls: [URL]) async -> [AtePhoto] {
        var resolved: [AtePhoto] = []
        for url in urls.prefix(2) {
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
