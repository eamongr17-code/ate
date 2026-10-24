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
    /// tapped and shrinks back into it on a swipe down or the close button (``AtePhotoFlight``).
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
    /// The viewer has its first frame up, photo over the tile: from then the tile itself is hidden.
    @State private var isUp = false

    func body(content: Content) -> some View {
        let viewingBinding = $viewing
        let zoomBinding = $zoomIndex
        let relay = relay
        content
            .environment(\.atePhotoOriginRelay, relay)
            .environment(\.atePhotoHiddenSource, isUp ? viewing.map(hiddenSource) : nil)
            .environment(\.atePhotoViewer, AtePhotoViewerAction { photos, index, dishes in
                guard photos.isEmpty == false else { return }
                AteTelemetry.record(BrowseEvents.photoPreviewOpened(photoCount: photos.count))
                let index = min(max(0, index), photos.count - 1)
                // The viewer draws its own grow out of the tile, so the cover itself goes up and
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
                    onShown: { isUp = true },
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

    /// The tile the photo showing now lands in, hidden while the viewer is up so it is never on the
    /// page twice: the one now showing, when the page has it, else none.
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
    /// Where each photo sits on the page, when a tile opened it: the photo grows out of its tile and
    /// lands back in it. Without one it fades.
    var origin: AtePhotoOrigin?
    var dishes: AtePhotoDishes?
    var onIndex: (Int) -> Void = { _ in }
    /// Its first frame is up, the photo over its tile.
    var onShown: () -> Void = {}
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
    @State private var isShowing = false
    /// The photo sits on its tile: as it opens, and again as it closes.
    @State private var isHome: Bool
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
        onShown: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.photos = photos
        _index = State(initialValue: index)
        self.origin = origin
        self.dishes = dishes
        _paired = State(initialValue: dishes?.paired ?? [:])
        // The picture's size before its first frame, from what the tile already drew: the grow has
        // to start on the tile.
        let size = photos.indices.contains(index) ? Self.cachedSize(photos[index]) : nil
        _imageSizes = State(initialValue: size.map { [index: $0] } ?? [:])
        _isHome = State(initialValue: origin?.tiles[index] != nil)
        self.onIndex = onIndex
        self.onShown = onShown
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AteColor.viewerGround
                .opacity(isShowing ? backdrop : 0)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    ZoomablePhoto(
                        photo: photo,
                        isZoomed: position == index ? $isZoomed : .constant(false),
                        onDrag: { drag = $0 },
                        onDragEnd: finishDrag,
                        onTap: { tapped(at: position) },
                        onImageSize: { size in if imageSizes[position] != size { imageSizes[position] = size } }
                    )
                    .overlay {
                        if position == index, isZoomed == false, drag == 0, isHome == false {
                            dishNames(at: position)
                        }
                    }
                    .tag(position)
                    .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
                    .accessibilityAddTraits(.isImage)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: showsDots ? .always : .never))
            .ignoresSafeArea()
            .modifier(AtePhotoFlight(landing: landing(at: index), isHome: isHome, drag: drag))
            .opacity(isShowing || landing(at: index) != nil ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            AteIconButton(icon: .close, label: "Close", size: 24, tint: AteColor.overPhoto) { close() }
                .padding(.leading, AteMetrics.snug)
                .opacity(isShowing && drag == 0 && isHome == false ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            dishName
                .opacity(isShowing && drag == 0 && isZoomed == false && isHome == false ? 1 : 0)
        }
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
        .onAppear {
            onShown()
            // Out of the tile, or (with no tile to come from) a fade.
            let animation: Animation = isHome ? AtePhotoViewerMetrics.fly : .easeOut(duration: 0.2)
            withAnimation(reduceMotion ? nil : animation) {
                isShowing = true
                isHome = false
            }
        }
        .onChange(of: index) { _, index in
            namesShown = false
            onIndex(index)
        }
        .task { await loadPairs() }
    }

    private var showsDots: Bool {
        photos.count > 1 && isZoomed == false && isShowing && isHome == false
    }

    /// Where the photo at `position` lands on its tile, when the page has one and its size is known.
    private func landing(at position: Int) -> AtePhotoLanding? {
        guard let tile = origin?.tiles[position] else { return nil }
        guard photos.indices.contains(position),
              let size = imageSizes[position] ?? Self.cachedSize(photos[position]) else { return nil }
        return AtePhotoLanding(tile: tile, image: size, screen: AteScreen.size)
    }

    /// The picture's size from the image cache (a stand-in has the photo's own shape).
    private static func cachedSize(_ photo: AtePhoto) -> CGSize? {
        guard let url = photo.url else { return nil }
        return AteImagePipeline.shared.bestCached(url, size: .full)?.image.size
    }

    /// The pairs as the server has them, unless a fix was made here in the meantime.
    private func loadPairs() async {
        guard let load = dishes?.load else { return }
        let before = paired
        let read = await load()
        guard paired == before, read.isEmpty == false else { return }
        paired = read
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
        // Back into its tile, when the page has it and the photo is at rest.
        if landing(at: index) != nil, isZoomed == false {
            withAnimation(reduceMotion ? nil : AtePhotoViewerMetrics.fly, completionCriteria: .removed) {
                isHome = true
                isShowing = false
            } completion: {
                onClose()
            }
            return
        }
        let animation: Animation? = reduceMotion ? nil : .easeIn(duration: 0.18)
        withAnimation(animation) {
            if flinging { drag = AteScreen.height }
            isShowing = false
        } completion: {
            onClose()
        }
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
