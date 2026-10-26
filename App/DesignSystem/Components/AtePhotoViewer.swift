import AteKit
import SwiftUI
import UIKit

// MARK: - Opening it

/// **Open the photo viewer** — the one way anything in the app shows a photo full screen. Read it
/// from the environment and call it with the photos and the one that was tapped:
///
/// ```swift
/// @Environment(\.atePhotoViewer) private var showPhotos
/// PhotoCluster(photos: photos, onTap: { showPhotos(photos, at: $0) })
/// ```
///
/// The shell hosts it (``SwiftUICore/View/atePhotoViewerHost()``), so a slip in the journal, a card
/// in the feed, the entry page and the dish page all open the same viewer, the same way.
struct AtePhotoViewerAction: Sendable {
    fileprivate var present: (@MainActor @Sendable ([AtePhoto], Int, AtePhotoDishes?) -> Void)?

    /// `dishes`: an entry's photos, with the dish each one is (0063) — the viewer names it under
    /// the photo, and on your own entry lets you fix it.
    @MainActor
    func callAsFunction(_ photos: [AtePhoto], at index: Int, dishes: AtePhotoDishes? = nil) {
        present?(photos, index, dishes)
    }
}

extension EnvironmentValues {
    @Entry var atePhotoViewer = AtePhotoViewerAction()
}

extension View {
    /// Hosts the photo viewer for everything beneath this view. A photo grows out of the tile that was
    /// tapped and lands back in it on a swipe down or the close button (``AtePhotoFlightImage``).
    func atePhotoViewerHost() -> some View {
        modifier(AtePhotoViewerHost())
    }
}

/// What the viewer is showing: every photo of one entry (or one dish), where it opened, and — when a
/// tile opened it — where each photo sits on the page, so the photo can grow out of it and shrink
/// back into it.
private struct AtePhotoViewing: Identifiable {
    let id = UUID()
    let photos: [AtePhoto]
    let index: Int
    var origin: AtePhotoOrigin?
    var dishes: AtePhotoDishes?
}

private struct AtePhotoViewerHost: ViewModifier {
    @State private var viewing: AtePhotoViewing?
    /// The photo showing now, so it lands back in the tile the reader swiped to.
    @State private var zoomIndex = 0
    @State private var relay = AtePhotoOriginRelay()
    /// The flying photo is on the screen over its tile: until it lands back, the tile itself is
    /// hidden, so the photo is never on the page twice.
    @State private var isUp = false

    func body(content: Content) -> some View {
        let viewingBinding = $viewing
        let zoomBinding = $zoomIndex
        let relay = relay
        content
            .environment(\.atePhotoOriginRelay, relay)
            .environment(\.atePhotoHiddenSource, isUp ? viewing.map(hiddenSource) : nil)
            .environment(\.atePhotoViewerIsUp, viewing != nil)
            .environment(\.atePhotoViewer, AtePhotoViewerAction { photos, index, dishes in
                guard photos.isEmpty == false else { return }
                AteTelemetry.record(BrowseEvents.photoPreviewOpened(photoCount: photos.count))
                let index = min(max(0, index), photos.count - 1)
                // The viewer draws its own flight out of the tile, so the cover itself goes up and
                // comes down without the system's slide or zoom.
                withTransaction(AtePhotoViewerHost.instant) {
                    zoomBinding.wrappedValue = index
                    viewingBinding.wrappedValue = AtePhotoViewing(
                        photos: photos,
                        index: index,
                        origin: relay.take(),
                        dishes: dishes
                    )
                }
            })
            .fullScreenCover(item: $viewing) { viewing in
                AtePhotoViewer(
                    photos: viewing.photos,
                    index: viewing.index,
                    origin: viewing.origin,
                    dishes: viewing.dishes,
                    onIndex: { zoomIndex = $0 },
                    onLeftTile: { isUp = true },
                    onLanded: { isUp = false },
                    onClose: {
                        withTransaction(AtePhotoViewerHost.instant) {
                            isUp = false
                            viewingBinding.wrappedValue = nil
                        }
                    }
                )
                // The page stays underneath: the viewer's own black fades over it, and the photo
                // flies between it and its tile (24 Oct: the system zoom shrank the whole screen,
                // black and all, into the tile).
                .presentationBackground(.clear)
            }
    }

    private static var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// The tile the photo showing now lands in: the one now showing, when the page has it, else none.
    private func hiddenSource(_ viewing: AtePhotoViewing) -> String {
        viewing.origin?.tiles[zoomIndex]?.sourceID ?? "photo.none"
    }
}

// MARK: - The viewer

/// **A photo, full screen.** Black, the picture whole, swipe between an entry's photos, pinch (or
/// double-tap) to zoom, and drag it down to put it back.
///
/// Deliberately the system's own shape rather than the app's — this is the one place in Ate that is
/// not paper. There is no chrome beyond the close button (design rule 1), no counter beyond the page
/// dots a multi-photo entry already earns, and no editing of the photo itself. The one caption is
/// an entry photo's dish (``AtePhotoDishCaption``), which is the only place a photo is named; a photo
/// of several dishes names each over it on a tap (``AtePhotoDishNames``).
struct AtePhotoViewer: View {
    let photos: [AtePhoto]
    /// Which one was tapped.
    @State var index: Int
    /// Where each photo sits on the page, when a tile opened it: the photo flies out of its tile and
    /// lands back in it. Without one it fades.
    var origin: AtePhotoOrigin?
    var dishes: AtePhotoDishes?
    var onIndex: (Int) -> Void = { _ in }
    /// The flying photo is on the screen over its tile: the tile can step aside.
    var onLeftTile: () -> Void = {}
    /// The photo is back on its tile, exactly: the tile can come back under it.
    var onLanded: () -> Void = {}
    var onClose: () -> Void

    /// The pairs as they stand here: a fix shows at once, and goes back if the server refuses it.
    @State private var paired: [String: [PhotoDishTag]]
    /// A tap on a photo of several dishes floats every one's name over it; another puts them away.
    @State private var namesShown = false
    /// The dish a dish page opened the photo on keeps its name up until the first tap (0083).
    @State private var focusShown = true
    /// Each page's picture size, once it has loaded: where the names land.
    @State private var imageSizes: [Int: CGSize] = [:]
    @State private var isZoomed = false
    @State private var drag: CGFloat = 0
    /// **The one number the open and the close run on**: 0 on the tile (or unseen), 1 open. The
    /// flying photo's place and shape, the black, the caption and the close button all follow it.
    @State private var openness: CGFloat = 0
    /// The photo flying instead of the pager, its way fixed before it sets off; `nil` at rest, and
    /// for a photo that fades.
    @State private var flight: AtePhotoFlightPath?
    @State private var isClosing = false
    /// Where the pager draws the photo now showing, in window coordinates: where the flight lands.
    @State private var page: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a drag has to travel, or how fast, before letting go puts the photo away.
    private static let dismissDistance: CGFloat = 110
    private static let dismissVelocity: CGFloat = 900

    init(
        photos: [AtePhoto],
        index: Int,
        origin: AtePhotoOrigin? = nil,
        dishes: AtePhotoDishes? = nil,
        onIndex: @escaping (Int) -> Void = { _ in },
        onLeftTile: @escaping () -> Void = {},
        onLanded: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.photos = photos
        _index = State(initialValue: index)
        self.origin = origin
        self.dishes = dishes
        _paired = State(initialValue: dishes?.paired ?? [:])
        // On its tile from the viewer's very first frame, over the tile it came from.
        _flight = State(initialValue: Self.path(photos, at: index, origin: origin, page: nil, drag: 0))
        self.onIndex = onIndex
        self.onLeftTile = onLeftTile
        self.onLanded = onLanded
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AteColor.viewerGround
                .opacity(Double(openness) * backdrop)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    ZoomablePhoto(
                        photo: photo,
                        isZoomed: position == index ? $isZoomed : .constant(false),
                        // Down only: a drag up has nowhere to put the photo, and slid it up off the
                        // black with the page showing through (build 200).
                        onDrag: { drag = max(0, $0) },
                        onDragEnd: finishDrag,
                        onTap: { tapped(at: position) },
                        onImageSize: { size in if imageSizes[position] != size { imageSizes[position] = size } }
                    )
                    .overlay {
                        if position == index, isZoomed == false, drag == 0, flight == nil {
                            dishNames(at: position)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .global) } action: { frame in
                        notePage(frame)
                    }
                    .tag(position)
                    .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
                    .accessibilityAddTraits(.isImage)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: showsDots ? .always : .never))
            .ignoresSafeArea()
            .modifier(AtePhotoDragged(drag: drag))
            // Hidden, not removed, while the photo flies: laid out and holding its picture, so it
            // is ready the moment the photo lands on it.
            .opacity(flight == nil ? Double(openness) : 0)
            if let flight {
                AtePhotoFlightImage(path: flight, progress: openness)
            }
        }
        .overlay(alignment: .topLeading) {
            AteIconButton(icon: .close, label: "Close", size: 24, tint: AteColor.overPhoto) { close() }
                .padding(.leading, AteMetrics.snug)
                .opacity(drag == 0 ? Double(openness) : 0)
        }
        .overlay(alignment: .bottom) {
            dishName
                .opacity(drag == 0 && isZoomed == false ? Double(openness) : 0)
        }
        .background { AteOnWindow { open() } }
        .statusBarHidden()
        .accessibilityIdentifier("entry.photoViewer")
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(named: Text("Close")) { close() }
        // VoiceOver: swipe up or down to page through the entry's photos.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if photos.indices.contains(index + 1) { index += 1 }
            case .decrement: if photos.indices.contains(index - 1) { index -= 1 }
            @unknown default: break
            }
        }
        // A link that arrives while a photo is up waits for it to close.
        .ateCoversThePage()
        .onChange(of: index) { _, index in
            namesShown = false
            onIndex(index)
        }
        .task { await loadPairs() }
    }

    private var showsDots: Bool {
        photos.count > 1 && isZoomed == false && flight == nil && isClosing == false
    }

    /// Where a page at rest draws its photo: a drag or a swipe to the next photo moves the pager,
    /// not where the photo lands.
    private func notePage(_ frame: CGRect) {
        let isAtRest: Bool = frame.minX.magnitude < 1 && drag == 0 && isZoomed == false
        guard isAtRest, frame != page else { return }
        page = frame
    }

    /// The viewer is in the window. One refresh later its first frame (the photo over its tile) is
    /// on the screen, so the tile steps aside; one more and the photo sets off, from a frame that
    /// is really there — not from one still being built, which skipped the whole flight the first
    /// time a launch opened a photo.
    private func open() {
        AteNextFrame.run {
            onLeftTile()
            AteNextFrame.run { fly() }
        }
    }

    private func fly() {
        guard isClosing == false else { return }
        guard flight != nil else {
            withAnimation(reduceMotion ? nil : AtePhotoViewerMetrics.fade) { openness = 1 }
            return
        }
        // Where the pager really is, now it has laid out: fixed for the whole way.
        flight = Self.path(photos, at: index, origin: origin, page: page, drag: 0)
        guard reduceMotion == false else {
            openness = 1
            flight = nil
            return
        }
        withAnimation(AtePhotoViewerMetrics.fly, completionCriteria: .removed) {
            openness = 1
        } completion: {
            // Exactly where the pager draws it: the pager takes over with nothing to move.
            guard isClosing == false else { return }
            flight = nil
        }
    }

    /// The photo at `position` on its tile and on the page, when it can fly between them: its tile
    /// is on the screen, and the picture the tile drew is on hand.
    private static func path(
        _ photos: [AtePhoto], at position: Int, origin: AtePhotoOrigin?, page: CGRect?, drag: CGFloat
    ) -> AtePhotoFlightPath? {
        guard let tile = origin?.tiles[position], PhotoFlight.canLand(on: tile.frame, screen: AteScreen.size),
              photos.indices.contains(position), let image = onHand(photos[position]) else { return nil }
        let screen = CGRect(origin: .zero, size: AteScreen.size)
        guard let away = PhotoFlight.away(
            image: image.size, page: page ?? screen, anchor: CGPoint(x: screen.midX, y: screen.midY), drag: drag
        ) else { return nil }
        return AtePhotoFlightPath(
            image: image, home: home(tile, image: image), away: away, ring: tile.ring,
            covers: covers(over: position, photos: photos, origin: origin)
        )
    }

    /// The picture a tile drew: a staged pick's own, or a server photo's copy on hand.
    private static func onHand(_ photo: AtePhoto) -> UIImage? {
        photo.picture ?? photo.url.flatMap { AteImagePipeline.shared.onHand($0, size: .full) }
    }

    /// A tile, exactly as the page draws it.
    private static func home(_ tile: AtePhotoOrigin.Tile, image: UIImage) -> PhotoFlight.Frame {
        let crop = tile.focus?.crop(imageSize: image.size, aspect: 1)
        return PhotoFlight.home(tile: tile.frame, radius: tile.radius, angle: tile.angle, image: image.size, crop: crop)
    }

    /// The cluster's photos stacked over the one at `position` (``PhotoFlight/covers(over:tiles:reach:)``),
    /// bottom first, so they are drawn over the flying photo as the page draws them.
    private static func covers(
        over position: Int, photos: [AtePhoto], origin: AtePhotoOrigin?
    ) -> [AtePhotoFlightPath.Cover] {
        let tiles = origin?.tiles ?? [:]
        return PhotoFlight.covers(over: position, tiles: tiles.mapValues { (frame: $0.frame, layer: $0.layer) })
            .compactMap { index in
                guard let over = tiles[index], photos.indices.contains(index),
                      let image = onHand(photos[index]) else { return nil }
                return AtePhotoFlightPath.Cover(image: image, frame: home(over, image: image), ring: over.ring)
            }
    }

    /// The pairs as the server has them, unless a fix was made here in the meantime.
    private func loadPairs() async {
        guard let load = dishes?.load else { return }
        let before = paired
        let read = await load()
        guard paired == before, read.isEmpty == false, read != paired else { return }
        // Fresh pairs fade in under the photo rather than popping in.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { paired = read }
    }

    /// The dishes the photo at `position` shows, in receipt order.
    private func dishesHere(_ position: Int) -> [AtePhotoDishPill.Dish] {
        guard let dishes, photos.indices.contains(position), let url = photos[position].url?.absoluteString
        else { return [] }
        return dishes.dishes(in: url, paired: paired)
    }

    /// The placed dishes of a photo that shows several (0083): only those can be named over it.
    private func placedNames(_ position: Int) -> [AtePhotoDishNames.Name] {
        guard let url = photos[position].url?.absoluteString else { return [] }
        let here = dishesHere(position)
        guard here.count > 1 else { return [] }
        let tags = paired[url] ?? []
        return here.compactMap { dish in
            guard let box = tags.first(where: { $0.reviewID == dish.id })?.box else { return nil }
            return AtePhotoDishNames.Name(id: dish.id, name: dish.name, box: box)
        }
    }

    /// The names floating over the photo now: all after a tap; before one, the dish a dish page
    /// opened it on.
    @ViewBuilder
    private func dishNames(at position: Int) -> some View {
        let placed = placedNames(position)
        let shown = namesShown ? placed : (focusShown ? placed.filter { $0.id == dishes?.focus } : [])
        if shown.isEmpty == false, let size = imageSizes[position] {
            AtePhotoDishNames(names: shown, imageSize: size)
        }
    }

    /// Tap: the names come up, or go away. A photo with nothing placed in it ignores the tap.
    private func tapped(at position: Int) {
        let placed = placedNames(position)
        guard placed.isEmpty == false else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            if namesShown {
                namesShown = false
                focusShown = false
            } else {
                namesShown = true
            }
        }
        if namesShown {
            AteTelemetry.record(BrowseEvents.photoDishNamesShown(dishCount: placed.count, own: dishes?.onPick != nil))
        }
    }

    /// The dishes the photo now showing is, as a caption with who and where (15 Oct, B). On your own
    /// entry the same caption, with a faint pencil to fix them (24 Oct, A). A photo of several names
    /// them all, or the one a dish page opened it on (0083).
    @ViewBuilder private var dishName: some View {
        if let dishes, photos.indices.contains(index), let url = photos[index].url?.absoluteString {
            let here = dishesHere(index)
            let focused = here.filter { $0.id == dishes.focus }
            let named = focused.isEmpty ? here : focused
            let byline = dishes.bylines[url] ?? dishes.byline
            let edit = dishes.onPick.map { pick in
                AtePhotoDishPill(dishes: here, choices: dishes.choices, onPick: { ticked in
                    choose(ticked, for: url, with: pick)
                })
            }
            if named.isEmpty == false || edit != nil {
                AtePhotoDishCaption(dish: named.map(\.name).joined(separator: " · "), byline: byline, edit: edit)
            }
        }
    }

    /// The photo is exactly these dishes; a dish that stays keeps where it sits (0083).
    private func choose(
        _ ticked: [AtePhotoDishPill.Dish], for url: String,
        with pick: @escaping @MainActor @Sendable (String, [UUID]) async -> Bool
    ) {
        let ids = ticked.map(\.id)
        let kept = paired[url] ?? []
        guard kept.map(\.reviewID) != ids else { return }
        let before = paired
        let next = ids.map { id in kept.first { $0.reviewID == id } ?? PhotoDishTag(reviewID: id) }
        paired[url] = next.isEmpty ? nil : next
        AteHaptics.key()
        Task {
            if await pick(url, ids) == false { paired = before }
        }
    }

    /// The black thins as the photo is dragged away, so the page underneath shows through.
    private var backdrop: Double {
        max(0, 1 - Double(abs(drag)) / 420)
    }

    private func finishDrag(translation: CGFloat, velocity: CGFloat) {
        if translation > Self.dismissDistance || velocity > Self.dismissVelocity {
            close(flinging: true)
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { drag = 0 }
        }
    }

    private func close(flinging: Bool = false) {
        guard isClosing == false else { return }
        isClosing = true
        // Back into its tile, from exactly where the pager has it (drag and all), when the page has
        // the tile and the photo is not zoomed.
        if isZoomed == false, let path = Self.path(photos, at: index, origin: origin, page: page, drag: drag) {
            flight = path
            guard reduceMotion == false else { return land() }
            // The photo takes the pager's place this frame and sets off the next: a view that
            // appears in the same update as the animation would start at its end, on the tile.
            AteNextFrame.run {
                withAnimation(AtePhotoViewerMetrics.fly, completionCriteria: .removed) {
                    openness = 0
                } completion: {
                    land()
                }
            }
            return
        }
        withAnimation(reduceMotion ? nil : AtePhotoViewerMetrics.fade) {
            if flinging { drag = AteScreen.height }
            openness = 0
        } completion: {
            onClose()
        }
    }

    /// On its tile, exactly: the tile comes back under the photo, and once that is on the screen the
    /// viewer goes, so the photo is never missing from the page for a frame.
    private func land() {
        onLanded()
        AteNextFrame.run { onClose() }
    }
}

#if DEBUG
#Preview("Photo viewer") {
    AtePhotoViewer(photos: [
        AtePhoto(url: URL(string: "asset://ragu")),
        AtePhoto(url: URL(string: "asset://prawn"))
    ], index: 1, onClose: {})
}
#endif
