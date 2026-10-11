import AteKit
import SwiftUI
import UIKit

/// **The ink share sheet** (11 Oct, approved; Spotify's layout): the cards you swipe between, their
/// colour dots, and one row of ways out. No title and no close; the sheet goes down by its handle.
///
/// The cards (``AteShareCard``): the receipt alone (a sticker), the ready-made story, and the 4:5 post
/// — the last two only with a photo to put on them. Under each card its dots: the sticker's paper,
/// the story's ground. Adjust (the crop disc after the dots) lets the photo be dragged and pinched,
/// out as far as the whole photo, with a blurred copy of it filling the spare room.
///
/// The sticker card is the printed receipt itself (``AtePrintedReceiptStage``), so after a review it
/// prints right there, takes the Place key, and a dish name can be tapped to fix it. The other cards
/// join it once it has printed.
struct V2ShareSheet: View {
    /// What the sticker card shows while the receipt prints (the composer's Printed face).
    struct Printing {
        var isPrinting = false
        var breathes = true
        var onAddPlace: (() -> Void)?
        var onFixDish: ((AteReceipt.Item) -> Void)?
        /// Fed out of the printer once, on arrival.
        var enters = false
    }

    let receipt: AteReceipt
    /// The entry's first photo, in hand. `nil` until it arrives, or when there is none.
    var photo: UIImage?
    let source: ReceiptShareSource
    /// The receipt has printed and the photo is in: the other cards and the row are live.
    var isLive = true
    var printing = Printing()
    /// In place of the row, when a print could not finish: "Print it again".
    var reprint: V2PrintedFoot.Pill?
    let analytics: AnalyticsRecorder
    var onFirstShare: (() -> Void)?
    var isPresenting: Binding<Bool>?

    @State private var current: AteShareFormat? = .sticker
    @State private var look = AteShareLook()
    @State private var isAdjusting = false
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?

    private var formats: [AteShareFormat] {
        guard isLive else { return [.sticker] }
        return photo == nil ? [.sticker, .story] : AteShareFormat.allCases
    }

    private var showing: AteShareFormat { current ?? .sticker }

    var body: some View {
        VStack(spacing: 0) {
            carousel
            controls
                .frame(height: V2ShareSheetMetrics.controlsHeight)
            Rectangle()
                .fill(AtePalette.ink.hairline)
                .frame(height: 1)
                .padding(.bottom, AteMetrics.section)
            foot
        }
        .environment(\.atePalette, .ink)
        .foregroundStyle(AtePalette.ink.fg)
        .onChange(of: photo == nil, initial: true) { _, hasNone in
            look.ground = hasNone ? .coral : .photo
        }
        .onChange(of: formats) { _, formats in
            if let current, formats.contains(current) == false { self.current = .sticker }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.sheet")
    }

    // MARK: - The cards

    private var carousel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: V2ShareSheetMetrics.gap) {
                ForEach(formats) { format in
                    slot(format)
                        .frame(width: V2ShareSheetMetrics.slot.width, height: V2ShareSheetMetrics.slot.height)
                        .id(format)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $current)
        .safeAreaPadding(.horizontal, (AteScreen.width - V2ShareSheetMetrics.slot.width) / 2)
        .scrollIndicators(.hidden)
        .scrollDisabled(isAdjusting || formats.count < 2)
        .scrollClipDisabled()
        .padding(.vertical, AteMetrics.section)
        .accessibilityIdentifier("share.receipt")
    }

    @ViewBuilder
    private func slot(_ format: AteShareFormat) -> some View {
        switch format {
        case .sticker:
            AtePrintedReceiptStage(
                receipt: receipt,
                isPrinting: printing.isPrinting,
                breathes: printing.breathes,
                onAddPlace: printing.onAddPlace,
                onFixDish: printing.onFixDish,
                enters: printing.enters,
                paperScale: V2ShareSheetMetrics.stickerWidth / AteShareSlipMetrics.width,
                paper: look.paper
            )
            .environment(\.colorScheme, .light)
            .ateShadow(.shareSticker)
        case .story, .post:
            let isFraming = isAdjusting && format == showing
            let preview = AteShareCardPreview(card: card(format), width: V2ShareSheetMetrics.width(format))
            preview
                .overlay { if isFraming { V2FramingGrid().allowsHitTesting(false) } }
                .contentShape(Rectangle())
                .gesture(framing(format, scale: preview.scale), including: isFraming ? .all : .none)
                .accessibilityLabel(format == .story ? "Story" : "Post")
        }
    }

    private func card(_ format: AteShareFormat) -> AteShareCard {
        AteShareCard(
            format: format, receipt: receipt, photo: photo, look: look,
            receiptOpacity: isAdjusting && format == showing ? V2ShareSheetMetrics.adjustingReceipt : 1
        )
    }

    // MARK: - Dots, or Adjust

    @ViewBuilder
    private var controls: some View {
        if isAdjusting {
            adjustBar
        } else if isLive {
            HStack(spacing: V2ShareSheetMetrics.swatchGap) {
                switch showing {
                case .sticker:
                    ForEach(AteSharePaper.allCases, id: \.self) { paper in
                        AteShareSwatch(fill: AnyShapeStyle(paper.colour), label: "\(paper.rawValue.capitalized) paper",
                                       isSelected: look.paper == paper) { look.paper = paper }
                    }
                case .story:
                    ForEach(grounds, id: \.self) { ground in
                        AteShareSwatch(
                            fill: AnyShapeStyle(ground.colour), photo: ground == .photo ? photo : nil,
                            label: ground == .photo ? "Your photo" : ground.rawValue.capitalized,
                            isSelected: look.ground == ground
                        ) { look.ground = ground }
                    }
                case .post:
                    EmptyView()
                }
                if showing != .sticker, photo != nil {
                    AteShareSwatch(icon: .crop, label: "Adjust photo") { isAdjusting = true }
                }
            }
        } else {
            Color.clear
        }
    }

    private var grounds: [AteShareGround] {
        photo == nil ? AteShareGround.allCases.filter { $0 != .photo } : AteShareGround.allCases
    }

    private var adjustBar: some View {
        HStack(spacing: AteMetrics.regular) {
            Button("Reset") { setFraming(.automatic, for: showing) }
                .buttonStyle(.glass)
            Slider(value: zoom, in: zoomRange)
                .tint(AteColor.coral)
                .accessibilityLabel("Zoom")
            Button("Done") { isAdjusting = false }
                .buttonStyle(.glassProminent)
                .tint(AtePalette.ink.fg)
                .foregroundStyle(AteColor.ink)
        }
        .padding(.horizontal, AteMetrics.gutter)
    }

    // MARK: - The photo's framing

    private var photoSize: CGSize { photo?.size ?? .zero }

    private var zoomRange: ClosedRange<CGFloat> {
        let frame = AteShareCard.photoFrame(showing, look: look)
        return PhotoFraming.minimumZoom(image: photoSize, frame: frame)...PhotoFraming.maximumZoom
    }

    private var zoom: Binding<CGFloat> {
        Binding {
            look.framing(for: showing).zoom
        } set: { zoom in
            var framing = look.framing(for: showing)
            framing.zoom = zoom
            setFraming(framing, for: showing)
        }
    }

    private func setFraming(_ framing: PhotoFraming, for format: AteShareFormat) {
        let frame = AteShareCard.photoFrame(format, look: look)
        look.setFraming(framing.clamped(image: photoSize, frame: frame), for: format)
    }

    /// Drag to move, pinch to zoom: on screen points, scaled back to the card's own.
    private func framing(_ format: AteShareFormat, scale: CGFloat) -> some Gesture {
        let frame = AteShareCard.photoFrame(format, look: look)
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? look.framing(for: format).offset
                if dragStart == nil { dragStart = start }
                var framing = look.framing(for: format)
                framing.offset = CGSize(
                    width: start.width + value.translation.width / scale / frame.width,
                    height: start.height + value.translation.height / scale / frame.height
                )
                setFraming(framing, for: format)
            }
            .onEnded { _ in dragStart = nil }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? look.framing(for: format).zoom
                if zoomStart == nil { zoomStart = start }
                var framing = look.framing(for: format)
                framing.zoom = start * value.magnification
                setFraming(framing, for: format)
            }
            .onEnded { _ in zoomStart = nil }
        return SimultaneousGesture(drag, pinch)
    }

    // MARK: - The row

    @ViewBuilder
    private var foot: some View {
        if let reprint {
            V2PrintedFoot(pill: reprint)
        } else {
            V2ReceiptShareRow(
                card: card(showing), source: source, isEnabled: isLive && isAdjusting == false,
                analytics: analytics, onFirstShare: onFirstShare, isPresenting: isPresenting
            )
            .padding(.bottom, AteSheetScaffoldMetrics.bareBottom)
            .accessibilityIdentifier("summary.share")
        }
    }
}

/// The rule of thirds over a photo being adjusted.
struct V2FramingGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for third in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: size.width * third, y: 0))
                path.addLine(to: CGPoint(x: size.width * third, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * third))
                path.addLine(to: CGPoint(x: size.width, y: size.height * third))
            }
            context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
    }
}

/// **One dot under a card** — a colour, the photo, or the Adjust disc — with a ring when chosen.
struct AteShareSwatch: View {
    var fill: AnyShapeStyle = AnyShapeStyle(Color.clear)
    var photo: UIImage?
    var icon: AteIcon?
    let label: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            ZStack {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else if let icon {
                    icon.view(size: V2ShareSheetMetrics.swatchIcon)
                } else {
                    Circle().fill(fill)
                }
            }
            .frame(width: V2ShareSheetMetrics.swatch, height: V2ShareSheetMetrics.swatch)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(palette.hairline, lineWidth: icon == nil ? 1 : 1.5) }
            .padding(V2ShareSheetMetrics.ringGap)
            .overlay { if isSelected { Circle().strokeBorder(palette.fg, lineWidth: 2) } }
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum V2ShareSheetMetrics {
    /// Every card sits in the same slot, so swiping lands each one centred.
    static let slot = CGSize(width: 260, height: 412)
    static let gap: CGFloat = 8
    /// How wide each card is drawn: the story fills the slot's height, the post its width.
    static func width(_ format: AteShareFormat) -> CGFloat {
        switch format {
        case .sticker: stickerWidth
        case .story: 231
        case .post: 260
        }
    }

    static let stickerWidth: CGFloat = 224
    static let controlsHeight: CGFloat = 64
    static let swatch: CGFloat = 30
    static let swatchIcon: CGFloat = 16
    static let ringGap: CGFloat = 4
    static let swatchGap: CGFloat = 6
    /// The receipt while its card's photo is adjusted.
    static let adjustingReceipt: Double = 0.35
    /// The sheet's height on the entry page: the cards, the dots, the row.
    static let sheetHeight: CGFloat = 660
}
