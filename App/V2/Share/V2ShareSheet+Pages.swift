import AteKit
import SwiftUI
import UIKit

/// The share sheet's pages, the cards they make, the dots under the card in front, and the pinch on
/// its photo.
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

    /// Which photo is which dish landed while a story or post is in front: its photo stays put, rather
    /// than the whole receipt jumping to the best dish's photo under the person's fingers.
    func holdPhotoInFront(_ before: [UUID: [Int]]) {
        guard let current, current.format != .sticker, picked[current.page] == nil else { return }
        let was = ShareReceiptPage.pages(for: receipt, available: photos.keys.sorted(), dishPhotos: before)
        if let first = was.first(where: { $0.id == current.page })?.photos.first { picked[current.page] = first }
    }

    /// The page's look, at the receipt size chosen for every card.
    func look(_ page: ShareReceiptPage) -> AteShareLook {
        var look = looks[page.id] ?? AteShareLook()
        look.isMini = isMini
        return look
    }

    func change(_ id: UUID, _ edit: (inout AteShareLook) -> Void) {
        var look = self.look(self.page(id))
        edit(&look)
        looks[id] = look
    }

    /// The cards a page has: the story and the post only with a photo for them (25 Oct, Eamon: no
    /// colour grounds).
    private func formats(_ page: ShareReceiptPage) -> [AteShareFormat] {
        image(page) == nil ? [.sticker] : AteShareFormat.allCases
    }

    /// The switch's cards: the story and the post only when there is a photo to put them on.
    var switchFormats: [AteShareFormat] {
        pages.contains { image($0) != nil } ? AteShareFormat.allCases : [.sticker]
    }

    var format: AteShareFormat {
        let format = chosen ?? opensOn
        return switchFormats.contains(format) ? format : switchFormats.last ?? .sticker
    }

    /// What swipes: the formats of the one receipt; or, split, every dish in the chosen format, the
    /// whole receipt first (it is what printed; 25 Oct, Eamon: on a story or post too, on one photo).
    var slots: [ShareSlot] {
        let pages = pages
        guard let whole = pages.last else { return [] }
        guard isWaiting == false else { return [] }
        guard isLive else { return [ShareSlot(format: .sticker, page: whole.id)] }
        guard isSplit else { return formats(whole).map { ShareSlot(format: $0, page: whole.id) } }
        let dishes = pages.filter { $0.isWhole == false }
        let shown: [ShareReceiptPage] = switch format {
        case .sticker: [whole] + dishes
        case .story, .post: ([whole] + dishes).filter { image($0) != nil }
        }
        return shown.map { ShareSlot(format: format, page: $0.id) }
    }

    var showing: ShareSlot {
        current ?? slots.first ?? ShareSlot(format: .sticker, page: receipt.id)
    }

    // MARK: - Dots

    @ViewBuilder
    var controls: some View {
        if isLive {
            let page = self.page(showing.page)
            let look = self.look(page)
            HStack(spacing: V2ShareSheetMetrics.swatchGap) {
                switch showing.format {
                case .sticker:
                    ForEach(AteSharePaper.allCases, id: \.self) { paper in
                        AteShareSwatch(fill: AnyShapeStyle(paper.colour), label: "\(paper.rawValue.capitalized) paper",
                                       isSelected: look.paper == paper) { change(page.id) { $0.paper = paper } }
                    }
                case .story, .post:
                    if page.photos.count > 1 {
                        photoSwatches(page)
                        Rectangle()
                            .fill(AtePalette.ink.hairline)
                            .frame(width: 1, height: V2ShareSheetMetrics.swatch)
                            .padding(.horizontal, V2ShareSheetMetrics.swatchGap)
                    }
                    sizeSwitch
                }
            }
            .transition(printing.enters ? .opacity.animation(V2ShareSheetMetrics.liveIn) : .opacity)
        } else {
            Color.clear
        }
    }

    /// Regular | Mini: the receipt's size on every story and post.
    private var sizeSwitch: some View {
        Picker("Receipt size", selection: $isMini) {
            Text("Regular").tag(false)
            Text("Mini").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("share.size")
    }

    /// A dot per photo the page can go on. Picking another starts its framing afresh.
    private func photoSwatches(_ page: ShareReceiptPage) -> some View {
        ForEach(page.photos, id: \.self) { position in
            let number = (page.photos.firstIndex(of: position) ?? 0) + 1
            AteShareSwatch(
                photo: photos[position],
                label: page.photos.count > 1 ? "Photo \(number)" : "Your photo",
                isSelected: self.position(page) == position
            ) {
                if self.position(page) != position {
                    picked[page.id] = position
                    change(page.id) {
                        $0.storyFraming = .automatic
                        $0.postFraming = .automatic
                    }
                }
            }
        }
    }

    // MARK: - The photo's framing

    private func photoSize(_ slot: ShareSlot) -> CGSize { image(page(slot.page))?.size ?? .zero }

    private func frame(_ slot: ShareSlot) -> CGSize {
        AteShareCard.photoFrame(slot.format, look: look(page(slot.page)))
    }

    private func setFraming(_ framing: PhotoFraming, for slot: ShareSlot) {
        let held = framing.clamped(image: photoSize(slot), frame: frame(slot))
        change(slot.page) { $0.setFraming(held, for: slot.format) }
    }

    func resetFraming(_ slot: ShareSlot) {
        guard slot.format != .sticker else { return }
        withAnimation(.snappy) { setFraming(.automatic, for: slot) }
    }

    /// A pinch scales the photo from where it started, and the fingers moving together move it: on
    /// screen points, scaled back to the card's own.
    func pinch(_ slot: ShareSlot, _ pinch: V2PhotoPinch.Value?, scale: CGFloat) {
        guard slot.format != .sticker else { return }
        guard let pinch else {
            dragStart = nil
            zoomStart = nil
            isPinching = false
            return
        }
        let frame = self.frame(slot)
        let now = look(page(slot.page)).framing(for: slot.format)
        let offset = dragStart ?? now.offset
        let zoom = zoomStart ?? now.zoom
        if dragStart == nil { dragStart = offset }
        if zoomStart == nil { zoomStart = zoom }
        isPinching = true
        var framing = now
        framing.zoom = zoom * pinch.scale
        framing.offset = CGSize(
            width: offset.width + pinch.translation.width / scale / frame.width,
            height: offset.height + pinch.translation.height / scale / frame.height
        )
        setFraming(framing, for: slot)
    }
}

/// **Two fingers on the photo**: how far apart they have spread, and how far they have moved together,
/// since they came down; `nil` once they lift. A UIKit pinch, because SwiftUI's own does not say where
/// the fingers went, and one finger is left to the cards and the receipt.
struct V2PhotoPinch: UIGestureRecognizerRepresentable {
    struct Value {
        var scale: CGFloat
        var translation: CGSize
    }

    let onChange: (Value?) -> Void

    final class Coordinator {
        /// The fingers' middle at the last change, and how many fingers made it: when one lifts or
        /// lands the middle jumps, so the count starts the motion afresh from there.
        var last: CGPoint?
        var touches = 0
        var moved = CGSize.zero
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        UIPinchGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let state = context.coordinator
        switch recognizer.state {
        case .began, .changed:
            let point = recognizer.location(in: recognizer.view)
            let touches = recognizer.numberOfTouches
            if let last = state.last, touches == state.touches {
                state.moved.width += point.x - last.x
                state.moved.height += point.y - last.y
            }
            state.last = point
            state.touches = touches
            onChange(Value(scale: recognizer.scale, translation: state.moved))
        default:
            state.last = nil
            state.touches = 0
            state.moved = .zero
            onChange(nil)
        }
    }
}
