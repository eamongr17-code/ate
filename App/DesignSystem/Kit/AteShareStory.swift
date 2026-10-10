import AteKit
import SwiftUI
import UIKit

/// **What leaves the app** — a 9:16 page (360 × 640, exported at 3× to Instagram's 1080 × 1920)
/// carrying the receipt as a sticker. With a photo it is the entry's photo full-bleed and the
/// receipt bottom-left at about two fifths of the width: the story people already post, with the
/// proof attached. Without one it is the receipt alone, a touch larger, centred on the coral ground.
/// Nobody picks: the entry decides.
///
/// The same view draws every exported layer, so what is approved on screen and what leaves cannot
/// disagree. `layer` picks which part is drawn: the whole page (Save image, Messages, More), the
/// background alone (Instagram's background layer), or the sticker alone on nothing (Instagram's
/// sticker layer).
struct AteShareStory: View {
    enum Layer: Equatable {
        case whole, background, sticker
    }

    let receipt: AteReceipt
    /// The photo behind the receipt. `nil` draws the coral ground.
    var photo: AtePhoto?
    var layer: Layer = .whole

    /// Which page this is, for the share count.
    var sticker: ShareSticker { photo == nil ? .slip : .photo }

    var body: some View {
        ZStack(alignment: photo == nil ? .center : .bottomLeading) {
            if layer != .sticker {
                background
            }
            if layer != .background {
                AteShareSlip(receipt: receipt)
                    .scaleEffect(photo == nil ? AteShareStoryMetrics.slipAloneScale : AteShareStoryMetrics.slipScale,
                                 anchor: photo == nil ? .center : .bottomLeading)
                    .padding(photo == nil ? 0 : AteShareStoryMetrics.inset)
            }
        }
        .frame(width: AteShareStoryMetrics.width, height: AteShareStoryMetrics.height)
        .clipped()
        .environment(\.atePalette, .accent(AteColor.coral))
        .foregroundStyle(AteColor.ink)
    }

    @ViewBuilder
    private var background: some View {
        if let photo {
            AtePhotoContent(photo: photo, contentMode: .fill)
                .frame(width: AteShareStoryMetrics.width, height: AteShareStoryMetrics.height)
                .clipped()
        } else {
            AteColor.coral
        }
    }
}

enum AteShareStoryMetrics {
    /// The story page, in points: Instagram's 1080 × 1920 at the export scale.
    static let width: CGFloat = 360
    static let height: CGFloat = 640
    /// How far the receipt sits in from the page's edge.
    static let inset: CGFloat = 22
    /// The receipt on a photo, at about two fifths of the width.
    static let slipScale: CGFloat = 0.8
    /// The receipt alone, a touch larger: it is the whole picture.
    static let slipAloneScale: CGFloat = 1.1
    static let radius: CGFloat = 18
}

/// **The story, rendered** — what each destination is handed.
struct AteShareRender {
    /// The whole page, opaque: Save image, Messages, More.
    let page: UIImage
    /// The receipt alone, on nothing: Instagram's sticker layer.
    let sticker: UIImage
    /// The photo alone, when there is one: Instagram's background layer. `nil` means the coral ground.
    let background: UIImage?
}

/// **The story as pictures.** Light, at the default text size: the reader's own settings belong on
/// the reader's screen, not in a picture sent to somebody else.
@MainActor
enum AteShareStoryImage {
    static func render(_ story: AteShareStory) -> AteShareRender? {
        guard let page = image(story, layer: .whole, opaque: true),
              let sticker = image(story, layer: .sticker, opaque: false) else { return nil }
        let background = story.photo == nil ? nil : image(story, layer: .background, opaque: true)
        return AteShareRender(page: page, sticker: sticker, background: background)
    }

    private static func image(_ story: AteShareStory, layer: AteShareStory.Layer, opaque: Bool) -> UIImage? {
        var story = story
        story.layer = layer
        let content = story
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
            .environment(\.ateIsSnapshotting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = AteMetrics.shareExportScale
        renderer.isOpaque = opaque
        guard let image = renderer.uiImage else { return nil }
        return layer == .sticker ? image.ateTrimmedToContent() : image
    }
}

extension UIImage {
    /// A transparent page cropped to the pixels it actually has — so a sticker pasted into a story
    /// is the receipt, not a full-screen clear rectangle with a receipt in one corner.
    func ateTrimmedToContent() -> UIImage {
        guard let cgImage, let alphaOffset = Self.alphaOffset(of: cgImage),
              let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return self }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var box = CGRect.null
        for row in 0..<cgImage.height {
            let rowStart = row * cgImage.bytesPerRow + alphaOffset
            for column in 0..<cgImage.width where bytes[rowStart + column * bytesPerPixel] > 0 {
                box = box.union(CGRect(x: column, y: row, width: 1, height: 1))
            }
        }
        guard box.isNull == false, let cropped = cgImage.cropping(to: box) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }

    /// Where a pixel's alpha byte sits, for the layouts `ImageRenderer` produces. `nil` is no alpha.
    private static func alphaOffset(of image: CGImage) -> Int? {
        switch image.alphaInfo {
        case .premultipliedFirst, .first: 0
        case .premultipliedLast, .last: image.bitsPerPixel / 8 - 1
        default: nil
        }
    }
}

#if DEBUG
#Preview("Share stories") {
    ScrollView(.horizontal) {
        HStack(spacing: AteMetrics.section) {
            AteShareStory(receipt: .preview, photo: AtePhoto.swatches.first)
            AteShareStory(receipt: .preview)
        }
        .padding()
    }
    .ateGround()
}
#endif
