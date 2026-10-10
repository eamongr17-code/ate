import AteKit
import SwiftUI
import UIKit

/// **What lands in a story** — a 9:16 page (360 × 640, exported at 3× to Instagram's 1080 × 1920)
/// carrying one of the three stickers:
///
/// - ``ShareSticker/photo`` — the entry's photo full-bleed, the slip bottom-left: the story people
///   already post, with the proof attached. The default.
/// - ``ShareSticker/slip`` — the slip alone, centred on the coral ground: for a better photo of
///   their own, an entry with none, or a paste onto a Reel.
/// - ``ShareSticker/dish`` — one photo, one dish's tag: the carousel format.
///
/// The same view draws the screen's preview and every exported layer, so what is approved and what
/// leaves cannot disagree. `layer` picks which part is drawn: the whole page, the background alone
/// (Instagram's background layer), or the sticker alone on nothing (Instagram's sticker layer, and the
/// clipboard).
struct AteShareStory: View {
    enum Layer: Equatable {
        case whole, background, sticker
    }

    let sticker: ShareSticker
    let receipt: AteReceipt
    /// The photo behind the slip or the tag. `nil` draws the coral ground.
    var photo: AtePhoto?
    /// The dish a ``ShareSticker/dish`` page tags.
    var dish: AteReceipt.Item?
    var layer: Layer = .whole

    var body: some View {
        ZStack(alignment: sticker == .slip ? .center : .bottomLeading) {
            if layer != .sticker {
                background
            }
            if layer != .background {
                stickerView
                    .padding(sticker == .slip ? 0 : AteShareStoryMetrics.inset)
            }
        }
        .frame(width: AteShareStoryMetrics.width, height: AteShareStoryMetrics.height)
        .clipped()
        .environment(\.atePalette, .accent(AteColor.coral))
        .foregroundStyle(AteColor.ink)
    }

    @ViewBuilder
    private var background: some View {
        if let photo, sticker != .slip {
            AtePhotoContent(photo: photo, contentMode: .fill)
                .frame(width: AteShareStoryMetrics.width, height: AteShareStoryMetrics.height)
                .clipped()
        } else {
            AteColor.coral
        }
    }

    @ViewBuilder
    private var stickerView: some View {
        switch sticker {
        case .photo, .slip:
            AteShareSlip(receipt: receipt)
                .scaleEffect(sticker == .slip ? AteShareStoryMetrics.slipAloneScale : AteShareStoryMetrics.slipScale,
                             anchor: sticker == .slip ? .center : .bottomLeading)
        case .dish:
            AteDishTag(name: dish?.name ?? "", score: dish?.score)
        }
    }

    /// Whether this page has a photo behind it — what decides Instagram's background layer.
    var hasPhotoBackground: Bool { photo != nil && sticker != .slip }
}

enum AteShareStoryMetrics {
    /// The story page, in points: Instagram's 1080 × 1920 at the export scale.
    static let width: CGFloat = 360
    static let height: CGFloat = 640
    /// How far the slip or tag sits in from the page's edge.
    static let inset: CGFloat = 22
    /// The slip on a photo, scaled down to about two fifths of the width.
    static let slipScale: CGFloat = 0.8
    /// The slip alone, a touch larger: it is the whole picture.
    static let slipAloneScale: CGFloat = 1.1
    static let radius: CGFloat = 18
}

/// **A sticker, rendered** — what each destination is handed.
struct AteShareRender {
    /// The whole page, opaque: Save image, Messages, More.
    let page: UIImage
    /// The slip or tag alone, on nothing: Instagram's sticker layer, and the clipboard.
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
        let background = story.hasPhotoBackground ? image(story, layer: .background, opaque: true) : nil
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
    /// is the slip, not a full-screen clear rectangle with a slip in one corner.
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
            AteShareStory(sticker: .photo, receipt: .preview, photo: AtePhoto.swatches.first)
            AteShareStory(sticker: .slip, receipt: .preview)
            AteShareStory(sticker: .dish, receipt: .preview, photo: AtePhoto.swatches.first,
                          dish: AteReceipt.preview.items.first)
        }
        .padding()
    }
    .ateGround()
}
#endif
