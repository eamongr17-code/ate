import AteKit
import SwiftUI
import UIKit

/// **The share card, as a picture.** The loop's last step: every entry ends in an artefact worth
/// posting (PRODUCT.md principle 6).
///
/// `ImageRenderer` over the *same* ``ShareCard`` the Share screen shows — rendering a second drawing
/// for export is exactly how the two drift apart, and the design's coral ground with its tilted
/// photos IS the artefact, not a frame around one.
///
/// What is left out is the chrome: Done and the Share pill are this app's furniture and have no
/// business in somebody else's camera roll.
@MainActor
enum ShareImage {
    /// The page the card was drawn on.
    static let width: CGFloat = 390
    /// How much coral is left above and below the composition. Enough that the top photo's corner,
    /// which hangs 30 above the paper, is inside the picture with room to breathe.
    static let padding: CGFloat = 40

    static func render(
        artefact: ShareArtefact,
        photos: [AtePhoto],
        scale: CGFloat = AteMetrics.shareExportScale
    ) -> UIImage? {
        let content = ShareCard(artefact: artefact, photos: photos)
            .padding(.horizontal, ShareCard.inset)
            .padding(.vertical, padding)
            .frame(width: width)
            .ateAccentGround(AteColor.coral)
            // The reader's own text size belongs on the reader's screen, not in a picture sent to
            // somebody else — and an accessibility size would burst the card's fixed width.
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
            // `ImageRenderer` paints a placeholder over any `UIViewRepresentable`. This tells the
            // two components that use one to draw themselves in plain SwiftUI instead — without it
            // every dish note on a shared receipt is a yellow warning stripe.
            .environment(\.ateIsSnapshotting, true)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// The system share sheet, given an already-rendered image.
///
/// A `UIViewControllerRepresentable` rather than SwiftUI's `ShareLink` because the thing being shared
/// is made at the moment of sharing, not held in the view's state — and because the activity
/// controller is the only way to be sure the image (not a URL, not a description) is what travels.
struct ShareSheet: UIViewControllerRepresentable {
    /// Whatever is being sent: the share card, or a link to a profile.
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    init(image: UIImage) {
        self.items = [image]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
