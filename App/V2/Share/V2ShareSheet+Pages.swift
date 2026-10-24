import AteKit
import SwiftUI
import UIKit

/// The share sheet's pages, the cards they make, and the dots and Adjust under the card in front.
extension V2ShareSheet {
    // MARK: - Pages and cards

    var pages: [ShareReceiptPage] {
        ShareReceiptPage.pages(for: receipt, available: photos.keys.sorted(), dishPhotos: dishPhotos)
    }

    /// A review of several dishes, printed: one receipt per dish, under the switch.
    var isSplit: Bool { isLive && receipt.items.count > 1 }

    /// From an entry, before the photos are in: no cards yet, so none shows and is swapped.
    var isWaiting: Bool { isLive == false && printsFirst == false }

    func page(_ id: UUID) -> ShareReceiptPage {
        pages.first { $0.id == id } ?? ShareReceiptPage(id: receipt.id, receipt: receipt, photos: [], isWhole: true)
    }

    /// The photo the page's cards are on: the one picked, or its first.
    func position(_ page: ShareReceiptPage) -> Int? {
        if let picked = picked[page.id], page.photos.contains(picked) { return picked }
        return page.photos.first
    }

    func image(_ page: ShareReceiptPage) -> UIImage? {
        position(page).flatMap { photos[$0] }
    }

    /// The page's look: on its photo until changed, and never a photo ground with no photo.
    func look(_ page: ShareReceiptPage) -> AteShareLook {
        var look = looks[page.id] ?? AteShareLook()
        if image(page) == nil, look.ground == .photo { look.ground = .coral }
        return look
    }

    func change(_ id: UUID, _ edit: (inout AteShareLook) -> Void) {
        var look = self.look(self.page(id))
        edit(&look)
        looks[id] = look
    }

    /// The cards a page has: the story and the post only with a photo for them.
    private func formats(_ page: ShareReceiptPage) -> [AteShareFormat] {
        image(page) == nil ? [.sticker, .story] : AteShareFormat.allCases
    }

    /// The switch's cards: the post only when a dish has a photo to put it on.
    var switchFormats: [AteShareFormat] {
        pages.contains { $0.isWhole == false && image($0) != nil } ? AteShareFormat.allCases : [.sticker, .story]
    }

    var format: AteShareFormat {
        let format = chosen ?? opensOn
        return switchFormats.contains(format) ? format : .story
    }

    /// What swipes: the formats of the one receipt; or, split, every dish in the chosen format (the
    /// whole receipt first among the stickers: it is what printed).
    var slots: [ShareSlot] {
        let pages = pages
        guard let whole = pages.last else { return [] }
        guard isWaiting == false else { return [] }
        guard isLive else { return [ShareSlot(format: .sticker, page: whole.id)] }
        guard isSplit else { return formats(whole).map { ShareSlot(format: $0, page: whole.id) } }
        let dishes = pages.filter { $0.isWhole == false }
        let shown: [ShareReceiptPage] = switch format {
        case .sticker: [whole] + dishes
        case .story: dishes
        case .post: dishes.filter { image($0) != nil }
        }
        return shown.map { ShareSlot(format: format, page: $0.id) }
    }

    var showing: ShareSlot {
        current ?? slots.first ?? ShareSlot(format: .sticker, page: receipt.id)
    }

    // MARK: - Dots, or Adjust

    @ViewBuilder
    var controls: some View {
        if isAdjusting {
            adjustBar
        } else if isLive {
            let page = self.page(showing.page)
            let look = self.look(page)
            HStack(spacing: V2ShareSheetMetrics.swatchGap) {
                switch showing.format {
                case .sticker:
                    ForEach(AteSharePaper.allCases, id: \.self) { paper in
                        AteShareSwatch(fill: AnyShapeStyle(paper.colour), label: "\(paper.rawValue.capitalized) paper",
                                       isSelected: look.paper == paper) { change(page.id) { $0.paper = paper } }
                    }
                case .story:
                    photoSwatches(page, isSelected: look.ground == .photo)
                    ForEach(AteShareGround.allCases.filter { $0 != .photo }, id: \.self) { ground in
                        AteShareSwatch(fill: AnyShapeStyle(ground.colour), label: ground.rawValue.capitalized,
                                       isSelected: look.ground == ground) { change(page.id) { $0.ground = ground } }
                    }
                case .post:
                    if page.photos.count > 1 { photoSwatches(page, isSelected: true) }
                }
                if showing.format != .sticker, image(page) != nil {
                    AteShareSwatch(icon: .crop, label: "Adjust photo") { isAdjusting = true }
                }
            }
        } else {
            Color.clear
        }
    }

    /// A dot per photo the page can go on. Picking another starts its framing afresh.
    private func photoSwatches(_ page: ShareReceiptPage, isSelected: Bool) -> some View {
        ForEach(page.photos, id: \.self) { position in
            let number = (page.photos.firstIndex(of: position) ?? 0) + 1
            AteShareSwatch(
                photo: photos[position],
                label: page.photos.count > 1 ? "Photo \(number)" : "Your photo",
                isSelected: isSelected && self.position(page) == position
            ) {
                if self.position(page) != position {
                    picked[page.id] = position
                    change(page.id) {
                        $0.storyFraming = .automatic
                        $0.postFraming = .automatic
                    }
                }
                change(page.id) { $0.ground = .photo }
            }
        }
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

    private func photoSize(_ slot: ShareSlot) -> CGSize { image(page(slot.page))?.size ?? .zero }

    private func frame(_ slot: ShareSlot) -> CGSize {
        AteShareCard.photoFrame(slot.format, look: look(page(slot.page)))
    }

    private var zoomRange: ClosedRange<CGFloat> {
        PhotoFraming.minimumZoom(image: photoSize(showing), frame: frame(showing))...PhotoFraming.maximumZoom
    }

    private var zoom: Binding<CGFloat> {
        Binding {
            look(page(showing.page)).framing(for: showing.format).zoom
        } set: { zoom in
            var framing = self.look(self.page(showing.page)).framing(for: showing.format)
            framing.zoom = zoom
            setFraming(framing, for: showing)
        }
    }

    private func setFraming(_ framing: PhotoFraming, for slot: ShareSlot) {
        let held = framing.clamped(image: photoSize(slot), frame: frame(slot))
        change(slot.page) { $0.setFraming(held, for: slot.format) }
    }

    /// Drag to move, pinch to zoom: on screen points, scaled back to the card's own.
    func framing(_ slot: ShareSlot, scale: CGFloat) -> some Gesture {
        let frame = self.frame(slot)
        let framingNow = { look(page(slot.page)).framing(for: slot.format) }
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? framingNow().offset
                if dragStart == nil { dragStart = start }
                var framing = framingNow()
                framing.offset = CGSize(
                    width: start.width + value.translation.width / scale / frame.width,
                    height: start.height + value.translation.height / scale / frame.height
                )
                setFraming(framing, for: slot)
            }
            .onEnded { _ in dragStart = nil }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? framingNow().zoom
                if zoomStart == nil { zoomStart = start }
                var framing = framingNow()
                framing.zoom = start * value.magnification
                setFraming(framing, for: slot)
            }
            .onEnded { _ in zoomStart = nil }
        return SimultaneousGesture(drag, pinch)
    }
}
