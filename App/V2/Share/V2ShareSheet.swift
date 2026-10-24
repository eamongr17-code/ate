import AteKit
import SwiftUI
import UIKit

/// **The ink share sheet** (11 Oct, approved; Spotify's layout): the cards you swipe between, their
/// colour dots, and one row of ways out. No title and no close; the sheet goes down by its handle.
///
/// The cards (``AteShareCard``): the receipt alone (a sticker), the ready-made story, and the 4:5 post
/// — the last only with a photo to put on it. Under each card its dots: the sticker's paper, the
/// story's photos and grounds, the post's photos. Adjust (the crop disc after the dots) lets the photo
/// be dragged and pinched, out as far as the whole photo, with a blurred copy of it filling the spare
/// room. On the card in front, the receipt can be dragged anywhere on the page.
///
/// **A review of several dishes** (23 Oct, Eamon, option B): one receipt per dish, on that dish's own
/// photos (``ShareReceiptPage``). Sticker, Story and Post become a switch over the cards, and the
/// cards swipe from dish to dish; the whole receipt is the first sticker.
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
    /// The entry's photos in hand, by position. Empty until they arrive, or when there are none.
    var photos: [Int: UIImage] = [:]
    /// Each dish's own photos (``SharePhotoPairs``); every photo for every dish until known.
    var dishPhotos: [UUID: [Int]] = [:]
    /// Which card a review of several dishes opens on.
    var opensOn: AteShareFormat = .story
    let source: ReceiptShareSource
    /// The receipt has printed and the photos are in: the other cards and the row are live.
    var isLive = true
    /// Until it is live, the sticker shows the receipt (after a review it prints there). From an
    /// entry there is nothing to print, so the cards wait and come in together, on the right one.
    var printsFirst = true
    var printing = Printing()
    /// In place of the row, when a receipt could not finish: "Try again".
    var reprint: V2PrintedFoot.Pill?
    /// In place of the row, while a receipt is slow, unfinished or offline (``ReceiptFallback``):
    /// the line saying the entry is saved and can be closed, above ``reprint`` when there is one.
    var note: String?
    let analytics: AnalyticsRecorder
    var onFirstShare: (() -> Void)?
    var isPresenting: Binding<Bool>?

    @State var current: ShareSlot?
    /// The switch over the cards, for a review of several dishes; `nil` is ``opensOn``.
    @State var chosen: AteShareFormat?
    /// Each page's paper, ground, framing and receipt spot, once changed.
    @State var looks: [UUID: AteShareLook] = [:]
    /// The photo picked on each page, by position; `nil` is its first.
    @State var picked: [UUID: Int] = [:]
    @State var isAdjusting = false
    @State var dragStart: CGSize?
    @State var zoomStart: CGFloat?
    /// Where a receipt drag started, and the receipt's laid-out size on each card.
    @State var receiptStart: UnitPoint?
    @State var receiptSizes: [ShareSlot: CGSize] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if isSplit {
                formatSwitch
            } else if isWaiting, receipt.items.count > 1 {
                Color.clear.frame(height: V2ShareSheetMetrics.switchHeight)
            }
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
        .onChange(of: slots, initial: true) { _, slots in
            if current.map(slots.contains) != true { current = slots.first }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.sheet")
    }

    // MARK: - The switch

    private var formatSwitch: some View {
        Picker("Card", selection: switchSelection) {
            ForEach(switchFormats) { format in
                Text(format.title).tag(format)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .frame(height: V2ShareSheetMetrics.switchHeight, alignment: .bottom)
        .disabled(isAdjusting)
        .accessibilityIdentifier("share.format")
    }

    /// A change of card keeps the dish in front, where that card has it.
    private var switchSelection: Binding<AteShareFormat> {
        Binding {
            format
        } set: { format in
            let page = current?.page
            chosen = format
            current = slots.first { $0.page == page } ?? slots.first
        }
    }

    // MARK: - The cards

    private var carousel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: V2ShareSheetMetrics.gap) {
                ForEach(slots) { slot in
                    self.slot(slot)
                        .frame(width: V2ShareSheetMetrics.slot.width, height: V2ShareSheetMetrics.slot.height)
                        .id(slot)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $current)
        .safeAreaPadding(.horizontal, (AteScreen.width - V2ShareSheetMetrics.slot.width) / 2)
        .scrollIndicators(.hidden)
        .scrollDisabled(isAdjusting || slots.count < 2)
        .scrollClipDisabled()
        .frame(height: V2ShareSheetMetrics.slot.height)
        .padding(.vertical, AteMetrics.section)
        .accessibilityIdentifier("share.receipt")
    }

    @ViewBuilder
    private func slot(_ slot: ShareSlot) -> some View {
        let page = self.page(slot.page)
        switch slot.format {
        case .sticker:
            AtePrintedReceiptStage(
                receipt: page.receipt,
                isPrinting: page.isWhole && printing.isPrinting,
                breathes: printing.breathes,
                onAddPlace: page.isWhole ? printing.onAddPlace : nil,
                onFixDish: printing.onFixDish,
                enters: page.isWhole && printing.enters,
                paperScale: V2ShareSheetMetrics.stickerWidth / AteShareSlipMetrics.width,
                paper: look(page).paper
            )
            .environment(\.colorScheme, .light)
            .ateShadow(.shareSticker)
        case .story, .post:
            let isFraming = isAdjusting && slot == showing
            let width = V2ShareSheetMetrics.width(slot.format)
            let canMove = isLive && isAdjusting == false && slot == showing
            let preview = AteShareCardPreview(
                card: card(slot, onDragReceipt: canMove ? { moveReceipt(on: slot, by: $0, width: width) } : nil),
                width: width
            )
            preview
                .overlay { if isFraming { V2FramingGrid().allowsHitTesting(false) } }
                .contentShape(Rectangle())
                .gesture(framing(slot, scale: preview.scale), including: isFraming ? .all : .subviews)
                .accessibilityLabel(label(slot.format.title, page))
        }
    }

    private func label(_ title: String, _ page: ShareReceiptPage) -> String {
        guard isSplit, page.isWhole == false, let dish = page.receipt.items.first else { return title }
        return "\(title), \(dish.name)"
    }

    func card(_ slot: ShareSlot, onDragReceipt: ((CGSize?) -> Void)? = nil) -> AteShareCard {
        let page = self.page(slot.page)
        return AteShareCard(
            format: slot.format, receipt: page.receipt, photo: image(page), look: look(page),
            receiptOpacity: isAdjusting && slot == showing ? V2ShareSheetMetrics.adjustingReceipt : 1,
            isReceiptHeld: receiptStart != nil && slot == showing,
            onReceiptSize: { receiptSizes[slot] = $0 },
            onDragReceipt: onDragReceipt
        )
    }

    // MARK: - The receipt's place

    /// Follows the finger: screen points, back to the page's, as a share of the room it can move in.
    private func moveReceipt(on slot: ShareSlot, by translation: CGSize?, width: CGFloat) {
        guard let translation else {
            receiptStart = nil
            return
        }
        let format = slot.format
        let look = self.look(self.page(slot.page))
        let start = receiptStart ?? look.receiptSpot(for: format)
        if receiptStart == nil {
            receiptStart = start
            AteHaptics.tick()
        }
        let pageSize = format.pageSize
        let scale = width / pageSize.width
        let room = AteReceiptSpotLayout.room(
            page: pageSize, receipt: receiptSizes[slot] ?? .zero,
            scale: format.receiptScale(on: look.ground), clear: format.receiptClear
        )
        func moved(_ from: CGFloat, _ by: CGFloat, _ across: CGFloat) -> CGFloat {
            across > 0 ? min(max(from + by / scale / across, 0), 1) : from
        }
        let spot = UnitPoint(
            x: moved(start.x, translation.width, room.width),
            y: moved(start.y, translation.height, room.height)
        )
        change(slot.page) { $0.setReceiptSpot(spot, for: format) }
    }

    // MARK: - The row

    @ViewBuilder
    private var foot: some View {
        if let note {
            VStack(spacing: 0) {
                Text(note)
                    .ateText(.kitReceiptFallback)
                    .foregroundStyle(AtePalette.ink.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AteMetrics.gutter + AteMetrics.regular)
                    .accessibilityIdentifier("summary.fallback")
                if let reprint {
                    V2PrintedFoot(pill: reprint)
                } else {
                    Color.clear.frame(height: AteSheetScaffoldMetrics.bareBottom)
                }
            }
            .transition(.opacity)
        } else if let reprint {
            V2PrintedFoot(pill: reprint)
        } else {
            V2ReceiptShareRow(
                card: card(showing), source: source, isEnabled: isLive && isAdjusting == false,
                oneDish: page(showing.page).isWhole == false,
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
    /// The Sticker / Story / Post switch over the cards, for a review of several dishes.
    static let switchHeight: CGFloat = 44
    static let swatch: CGFloat = 30
    static let swatchIcon: CGFloat = 16
    static let ringGap: CGFloat = 4
    static let swatchGap: CGFloat = 6
    /// The receipt while its card's photo is adjusted.
    static let adjustingReceipt: Double = 0.35
    /// How fast an entry's cards come in once its photos are.
    static let cardsIn: Double = 0.2
    /// The sheet's height on the entry page: the cards, the dots, the row.
    static let sheetHeight: CGFloat = 660

    /// …and with the switch, for a receipt of several dishes.
    static func sheetHeight(dishes: Int) -> CGFloat {
        dishes > 1 ? sheetHeight + switchHeight : sheetHeight
    }
}
