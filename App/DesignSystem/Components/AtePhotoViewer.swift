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
    /// Hosts the photo viewer for everything beneath this view. A photo opens with the system's own
    /// `.zoom` transition, growing out of the tile that was tapped and shrinking back into it on a
    /// swipe down (round 4, Eamon picked B).
    func atePhotoViewerHost() -> some View {
        modifier(AtePhotoViewerHost())
    }
}

/// What the viewer is showing: every photo of one entry (or one dish), where it opened, and — when a
/// tile opened it — where each photo sits on the page, so the zoom can grow out of it and shrink
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
    /// The photo showing now, so the zoom shrinks back into the tile the reader swiped to.
    @State private var zoomIndex = 0
    @State private var relay = AtePhotoOriginRelay()
    /// The swipe down has started: the black behind goes, so only the photo shrinks into its tile.
    @State private var isLeaving = false
    @Namespace private var zoomSpace

    func body(content: Content) -> some View {
        let viewingBinding = $viewing
        let zoomBinding = $zoomIndex
        let leavingBinding = $isLeaving
        let relay = relay
        content
            .environment(\.atePhotoOriginRelay, relay)
            .environment(\.atePhotoZoomNamespace, zoomSpace)
            .environment(\.atePhotoViewer, AtePhotoViewerAction { photos, index, dishes in
                guard photos.isEmpty == false else { return }
                AteTelemetry.record(BrowseEvents.photoPreviewOpened(photoCount: photos.count))
                let index = min(max(0, index), photos.count - 1)
                // Before the cover goes up: the zoom reads its source as it presents, and a stale
                // index grew every photo out of the first tile (15 Oct).
                zoomBinding.wrappedValue = index
                leavingBinding.wrappedValue = false
                viewingBinding.wrappedValue = AtePhotoViewing(
                    photos: photos,
                    index: index,
                    origin: relay.take(),
                    dishes: dishes
                )
            })
            .fullScreenCover(item: $viewing) { viewing in
                AtePhotoViewer(
                    photos: viewing.photos,
                    index: viewing.index,
                    dragsToDismiss: false,
                    dishes: viewing.dishes,
                    onIndex: { zoomIndex = $0 },
                    onLeaving: { isLeaving = $0 },
                    onClose: { viewingBinding.wrappedValue = nil }
                )
                .navigationTransition(.zoom(sourceID: zoomSource(viewing), in: zoomSpace))
                // The viewer's own black is the ground; the cover's would shrink with the photo as a
                // slab round it (24 Oct).
                .presentationBackground(.clear)
            }
            // Black behind the viewer while it is up: the zoom draws the photo inside the screen's
            // rounded corners, and the page showed round its edges (feedback #1 and #2, 22 Oct;
            // Eamon picked this over dropping the zoom).
            .overlay {
                AteColor.viewerGround
                    .ignoresSafeArea()
                    .opacity(isBlack ? 1 : 0)
                    .animation(.easeOut(duration: AtePhotoViewerHostMetrics.behind), value: isBlack)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private var isBlack: Bool { viewing != nil && isLeaving == false }

    /// The tile the zoom grows from and returns to: the one now showing, when the page has it (a
    /// slip's cluster shows three of an entry's photos), else the one that was tapped.
    private func zoomSource(_ viewing: AtePhotoViewing) -> String {
        let tiles = viewing.origin?.tiles ?? [:]
        return tiles[zoomIndex]?.sourceID ?? tiles[viewing.index]?.sourceID ?? "photo.none"
    }
}

enum AtePhotoViewerHostMetrics {
    /// How fast the page goes black behind the viewer, and comes back.
    static let behind: Double = 0.2
    /// How fast the black, the close button and the caption go once the swipe down starts.
    static let leaving: Double = 0.12
}

/// Tells its view when the screen it is on starts to appear or go: UIKit's `viewWillAppear` and
/// `viewWillDisappear`, which a system transition (the zoom's swipe down) calls the moment it begins,
/// and calls again if it is let go short.
struct AteAppearanceProbe: UIViewControllerRepresentable {
    let onChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> Probe {
        Probe(onChange: onChange)
    }

    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: UIViewController {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onChange(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onChange(false)
        }
    }
}

// MARK: - The viewer

/// **A photo, full screen.** Black, the picture whole, swipe between an entry's photos, pinch (or
/// double-tap) to zoom, and drag it down to put it back.
///
/// Deliberately the system's own shape rather than the app's — this is the one place in Ate that is
/// not paper. There is no chrome beyond the close button (design rule 1), no counter beyond the page
/// dots a multi-photo entry already earns, and no editing of the photo itself. The one caption is
/// an entry photo's dish (``AtePhotoDishPill``), which is the only place a photo is named; a photo
/// of several dishes names each over it on a tap (``AtePhotoDishNames``).
struct AtePhotoViewer: View {
    let photos: [AtePhoto]
    /// Which one was tapped.
    @State var index: Int
    /// Off under the native zoom (B), whose own drag-down owns the dismissal.
    var dragsToDismiss = true
    var dishes: AtePhotoDishes?
    var onIndex: (Int) -> Void = { _ in }
    /// The zoom has started taking it away (`true`), or the swipe was let go short of it (`false`).
    var onLeaving: (Bool) -> Void = { _ in }
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
    /// Under the zoom, from the moment the swipe down starts: the photo alone goes back to its tile,
    /// without the black, the close button, the caption or the dots.
    @State private var isLeaving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a drag has to travel, or how fast, before letting go puts the photo away.
    private static let dismissDistance: CGFloat = 110
    private static let dismissVelocity: CGFloat = 900

    init(
        photos: [AtePhoto],
        index: Int,
        dragsToDismiss: Bool = true,
        dishes: AtePhotoDishes? = nil,
        onIndex: @escaping (Int) -> Void = { _ in },
        onLeaving: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.photos = photos
        _index = State(initialValue: index)
        self.dragsToDismiss = dragsToDismiss
        self.dishes = dishes
        _paired = State(initialValue: dishes?.paired ?? [:])
        self.onIndex = onIndex
        self.onLeaving = onLeaving
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AteColor.viewerGround
                .opacity(isShowing && isLeaving == false ? backdrop : 0)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    ZoomablePhoto(
                        photo: photo,
                        isZoomed: position == index ? $isZoomed : .constant(false),
                        dragsToDismiss: dragsToDismiss,
                        onDrag: { drag = $0 },
                        onDragEnd: finishDrag,
                        onTap: { tapped(at: position) },
                        onImageSize: { size in if imageSizes[position] != size { imageSizes[position] = size } }
                    )
                    .overlay {
                        if position == index, isZoomed == false, drag == 0, isLeaving == false {
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
            .offset(y: drag)
            .opacity(isShowing ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            AteIconButton(icon: .close, label: "Close", size: 24, tint: AteColor.overPhoto) { close() }
                .padding(.leading, AteMetrics.snug)
                .opacity(isShowing && drag == 0 && isLeaving == false ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            dishName
                .opacity(isShowing && drag == 0 && isZoomed == false && isLeaving == false ? 1 : 0)
        }
        .statusBarHidden()
        .background {
            if dragsToDismiss == false {
                AteAppearanceProbe { appearing in leaving(appearing == false) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
            // Under the zoom the transition itself brings the photo in; a fade on top of it would
            // start the grow from black.
            guard dragsToDismiss else {
                isShowing = true
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isShowing = true }
        }
        .onChange(of: index) { _, index in
            namesShown = false
            onIndex(index)
        }
        .task { await loadPairs() }
    }

    private var showsDots: Bool {
        photos.count > 1 && isZoomed == false && isLeaving == false
    }

    /// The zoom's own swipe down began (or was let go short): everything but the photo goes quickly,
    /// so what shrinks into the tile is the picture alone.
    private func leaving(_ leaving: Bool) {
        guard leaving != isLeaving else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: AtePhotoViewerHostMetrics.leaving)) {
            isLeaving = leaving
        }
        onLeaving(leaving)
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

    /// The dishes the photo now showing is. On your own entry a pill that is a menu to fix them; on
    /// anybody else's a caption, with who and where, so it never reads as a button (15 Oct, B). A
    /// photo of several names them all, or the one a dish page opened it on (0083).
    @ViewBuilder private var dishName: some View {
        if let dishes, photos.indices.contains(index), let url = photos[index].url?.absoluteString {
            let here = dishesHere(index)
            if dishes.onPick == nil {
                let focused = here.filter { $0.id == dishes.focus }
                let named = focused.isEmpty ? here : focused
                if named.isEmpty == false {
                    AtePhotoDishCaption(
                        dish: named.map(\.name).joined(separator: " · "), byline: dishes.bylines[url] ?? dishes.byline
                    )
                }
            } else {
                AtePhotoDishPill(dishes: here, choices: dishes.choices, onPick: dishes.onPick.map { pick in
                    { (ticked: [AtePhotoDishPill.Dish]) in choose(ticked, for: url, with: pick) }
                })
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, AtePhotoDishPillMetrics.bottom)
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
        guard dragsToDismiss else {
            onClose()
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
