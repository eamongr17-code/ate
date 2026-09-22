import AteKit
import SwiftUI
import UIKit

/// **The receipt, as a picture.** The loop's last step: every entry ends in an artefact worth
/// posting (PRODUCT.md principle 6).
///
/// `ImageRenderer` over the *same* `ReceiptView` the entry page shows — design rule 4 says Entry and
/// Share show the identical receipt component, and rendering a second drawing for export is exactly
/// how the two drift apart. The share card's coral ground and its framing are a milestone-2 screen;
/// what leaves the app today is the paper itself, on the paper's own background, at 3×.
@MainActor
enum ReceiptImage {
    /// The width the receipt is laid out at before scaling. The design's own: a 390pt screen minus
    /// the 22pt inset either side.
    static let width: CGFloat = 390 - 44

    static func render(_ receipt: AteReceipt, scale: CGFloat = AteMetrics.shareExportScale) -> UIImage? {
        let content = ReceiptView(receipt: receipt)
            .frame(width: width)
            // The paper needs something behind it: the torn edge is a real cut-out, so a transparent
            // background would put the teeth on whatever the receiving app happens to be.
            .padding(AteMetrics.section)
            .background(AteColor.ground)
            .environment(\.colorScheme, .light)

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
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
