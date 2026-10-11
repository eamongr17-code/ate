import AteKit
import SwiftUI
import UIKit

/// **The share sheet's three cards** (11 Oct, approved: the ink share sheet). Each has one job:
///
/// - **Sticker** — the receipt alone, on nothing. Sent to Instagram it is a sticker in the story
///   camera; the person brings their own picture. The paper can be white or an accent.
/// - **Story** — a finished 9:16 story (1080 × 1920): the photo full-bleed, or an accent ground with
///   the photo as a print, and the whole receipt across the foot. Never a cut-down tag.
/// - **Post** — 4:5 (1080 × 1350), for TikTok photo carousels and the Instagram feed: the photo
///   full-bleed with the receipt on it.
///
/// The same view draws the card on screen and every layer that leaves, so the two cannot disagree.
/// Always light: what leaves is a picture for somebody else's phone.
struct AteShareCard: View {
    enum Layer: Equatable {
        /// The whole card.
        case whole
        /// Everything but the receipt: Instagram's background layer.
        case background
        /// The receipt alone, on nothing: Instagram's sticker layer.
        case receipt
    }

    let format: AteShareFormat
    let receipt: AteReceipt
    /// The entry's first photo. `nil` and the story is an accent ground with no print.
    var photo: UIImage?
    var look = AteShareLook()
    var layer: Layer = .whole
    /// On screen while the photo is adjusted: the receipt steps back so the photo can be seen.
    var receiptOpacity: Double = 1

    var body: some View {
        Group {
            switch format {
            case .sticker:
                AteShareSlip(receipt: receipt, paper: look.paper)
            case .story, .post:
                page
            }
        }
        .environment(\.colorScheme, .light)
        .environment(\.atePalette, .accent(AteColor.coral))
    }

    private var page: some View {
        let size = format.pageSize
        return ZStack(alignment: .bottom) {
            if layer != .receipt {
                ground(size: size)
            }
            if layer != .background {
                AteShareSlip(receipt: receipt)
                    .scaleEffect(format.receiptScale, anchor: .bottom)
                    .padding(.bottom, format.receiptInset)
                    .opacity(receiptOpacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func ground(size: CGSize) -> some View {
        let framing = look.framing(for: format)
        if let photo, format == .post || look.ground == .photo {
            AteFramedPhoto(image: photo, framing: framing, size: size)
        } else {
            ZStack(alignment: .top) {
                look.ground.colour
                if let photo {
                    AteFramedPhoto(image: photo, framing: framing, size: AteShareCardMetrics.printSize)
                        .clipShape(RoundedRectangle(cornerRadius: AteShareCardMetrics.printRadius, style: .continuous))
                        .shadow(color: AteColor.ink.opacity(0.35), radius: 12, y: 8)
                        .rotationEffect(.degrees(AteShareCardMetrics.printTilt))
                        .padding(.top, AteShareCardMetrics.printTop)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// The frame the photo is framed in, in the card's own points: the whole page, or the print.
    static func photoFrame(_ format: AteShareFormat, look: AteShareLook) -> CGSize {
        format == .story && look.ground != .photo ? AteShareCardMetrics.printSize : format.pageSize
    }
}

/// Which card.
enum AteShareFormat: String, CaseIterable, Identifiable {
    case sticker, story, post

    var id: String { rawValue }

    /// The card, for the share count.
    var counted: ShareSticker {
        switch self {
        case .sticker: .sticker
        case .story: .story
        case .post: .post
        }
    }

    /// The page in points, exported at 3×. A sticker is the receipt's own size.
    var pageSize: CGSize {
        switch self {
        case .sticker: CGSize(width: AteShareSlipMetrics.width, height: AteShareSlipMetrics.width)
        case .story: CGSize(width: 360, height: 640)
        case .post: CGSize(width: 360, height: 450)
        }
    }

    /// The receipt's scale on the page: about three quarters of a story's width, a touch less on a post.
    var receiptScale: CGFloat {
        switch self {
        case .sticker: 1
        case .story: 1.3
        case .post: 1.15
        }
    }

    /// How far the receipt's foot sits above the page's: clear of Instagram's reply bar on a story.
    var receiptInset: CGFloat {
        switch self {
        case .sticker: 0
        case .story: 56
        case .post: 22
        }
    }
}

/// The sticker's paper.
enum AteSharePaper: String, CaseIterable {
    case white, butter, pink, sky

    var colour: Color {
        switch self {
        case .white: .white
        case .butter: AteColor.butter
        case .pink: AteColor.pink
        case .sky: AteColor.sky
        }
    }

    var tone: AtePaperTone { self == .white ? .slip : .accent(colour) }
}

/// The story's ground: the photo itself, or an accent with the photo as a print.
enum AteShareGround: String, CaseIterable {
    case photo, coral, butter, ink

    var colour: Color {
        switch self {
        case .photo: .black
        case .coral: AteColor.coral
        case .butter: AteColor.butter
        case .ink: AteColor.ink
        }
    }
}

/// Everything a person can change about the cards: the colours, and where the photo sits on each.
struct AteShareLook: Equatable {
    var paper: AteSharePaper = .white
    var ground: AteShareGround = .photo
    var storyFraming = PhotoFraming.automatic
    var postFraming = PhotoFraming.automatic

    func framing(for format: AteShareFormat) -> PhotoFraming {
        format == .post ? postFraming : storyFraming
    }

    mutating func setFraming(_ framing: PhotoFraming, for format: AteShareFormat) {
        if format == .post { postFraming = framing } else { storyFraming = framing }
    }

    /// The colour choice, for the share count.
    func name(for format: AteShareFormat) -> String {
        switch format {
        case .sticker: paper.rawValue
        case .story: ground.rawValue
        case .post: AteShareGround.photo.rawValue
        }
    }

    /// The photo was moved or zoomed off its automatic crop on this card.
    func isAdjusted(_ format: AteShareFormat) -> Bool {
        format != .sticker && framing(for: format).isAdjusted
    }
}

/// **A photo in a frame, where the person put it** (``PhotoFraming``). Zoomed out past the fill, the
/// spare room is the same photo, blurred — never a flat colour.
struct AteFramedPhoto: View {
    let image: UIImage
    let framing: PhotoFraming
    let size: CGSize

    var body: some View {
        let held = framing.clamped(image: image.size, frame: size)
        let drawn = held.drawnSize(image: image.size, frame: size)
        ZStack {
            if drawn.width < size.width - 0.5 || drawn.height < size.height - 0.5 {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: AteShareCardMetrics.fillBlur, opaque: true)
                    .clipped()
            }
            Image(uiImage: image)
                .resizable()
                .frame(width: drawn.width, height: drawn.height)
                .offset(held.offsetPoints(in: size))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// **A card, at the size it has on screen** — the export drawing, scaled down whole.
struct AteShareCardPreview: View {
    let card: AteShareCard
    /// How wide it is drawn.
    let width: CGFloat

    var scale: CGFloat { width / card.format.pageSize.width }

    var body: some View {
        AteScaledLayout(scale: scale) {
            card.scaleEffect(scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: AteShareCardMetrics.previewRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.45), radius: 16, y: 10)
    }
}

enum AteShareCardMetrics {
    /// The print above the receipt on an accent story.
    static let printSize = CGSize(width: 200, height: 226)
    static let printRadius: CGFloat = 10
    static let printTilt: Double = 3
    static let printTop: CGFloat = 70
    /// The blur on the photo filling the room a zoomed-out photo leaves.
    static let fillBlur: CGFloat = 28
    static let previewRadius: CGFloat = 16
}

/// **The cards as pictures.** Light, at the default text size: the reader's own settings belong on
/// the reader's screen, not in a picture sent to somebody else.
@MainActor
enum AteShareCardImage {
    static func render(_ card: AteShareCard) -> AteShareRender? {
        switch card.format {
        case .sticker:
            guard let sticker = image(card, layer: .whole, opaque: false)?.ateTrimmedToContent() else { return nil }
            return AteShareRender(page: sticker, sticker: sticker, background: nil)
        case .story, .post:
            guard let page = image(card, layer: .whole, opaque: true),
                  let sticker = image(card, layer: .receipt, opaque: false)?.ateTrimmedToContent(),
                  let background = image(card, layer: .background, opaque: true) else { return nil }
            return AteShareRender(page: page, sticker: sticker, background: background)
        }
    }

    private static func image(_ card: AteShareCard, layer: AteShareCard.Layer, opaque: Bool) -> UIImage? {
        var card = card
        card.layer = layer
        card.receiptOpacity = 1
        let content = card
            .environment(\.dynamicTypeSize, .large)
            .environment(\.ateIsSnapshotting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = AteMetrics.shareExportScale
        renderer.isOpaque = opaque
        return renderer.uiImage
    }
}

#if DEBUG
#Preview("Share cards") {
    ScrollView(.horizontal) {
        HStack(spacing: AteMetrics.section) {
            AteShareCard(format: .sticker, receipt: .preview, look: AteShareLook(paper: .butter))
            AteShareCardPreview(card: AteShareCard(format: .story, receipt: .preview), width: 231)
            AteShareCardPreview(card: AteShareCard(format: .post, receipt: .preview), width: 260)
        }
        .padding()
    }
    .background(AteColor.ink)
}
#endif
