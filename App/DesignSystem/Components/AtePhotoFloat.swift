import AteKit
import SwiftUI

/// **A photo, floating over the page it was tapped on** (round 5, Eamon: "the image should show up
/// above a blurred-out screen"). The page stays where it is, blurred and dimmed; the photo grows out
/// of the tile it was tapped on to a rounded card in the middle of the screen.
///
/// - Swipe sideways for the entry's other photos.
/// - Pinch to zoom (the card grows over the blur), drag to look around while zoomed, double-tap to
///   zoom in or back out; pinching it smaller than it rests puts it away.
/// - Swipe down, or tap the blurred page, and it shrinks back into its tile.
///
/// Two layouts under exploration (`-ate-r5-photo A|B`):
/// - **A — whole**: the photo at its own shape, as large as the screen allows; nothing else.
/// - **B — peek**: a 4:5 card a little narrower than the screen, the photos either side peeking in
///   at its edges, and a row of dots under it.
struct AtePhotoFloat: View {
    enum Layout: Equatable {
        case whole
        case peek
    }

    let photos: [AtePhoto]
    let origin: AtePhotoOrigin?
    let layout: Layout
    let onClose: () -> Void

    @State private var index: Int
    @State private var isOpen = false
    @State private var drag: CGSize = .zero
    @State private var axis: Axis?
    /// The zoom at rest, and the pinch in progress on top of it.
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    /// Where a zoomed photo has been dragged to, and the drag in progress.
    @State private var pan: CGSize = .zero
    /// Each photo's own shape (width / height) once known — layout A draws it whole.
    @State private var aspects: [Int: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(photos: [AtePhoto], index: Int, origin: AtePhotoOrigin?, layout: Layout, onClose: @escaping () -> Void) {
        self.photos = photos
        self.origin = origin
        self.layout = layout
        self.onClose = onClose
        _index = State(initialValue: index)
    }

    private static let dismissDistance: CGFloat = 110
    private static let pageDistance: CGFloat = 80
    private static let cardRadius: CGFloat = 28
    private static let maxZoom: CGFloat = 4
    private static let open = Animation.spring(duration: 0.42, bounce: 0.16)
    private static let shut = Animation.spring(duration: 0.34, bounce: 0.06)

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            ZStack(alignment: .topLeading) {
                backdrop
                    .opacity(backdropOpacity)
                    .contentShape(.rect)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                if layout == .peek || axis == .horizontal { neighbours(screen) }
                card(index, screen: screen)
                if layout == .peek, photos.count > 1 {
                    dots
                        .position(x: screen.width / 2, y: target(index, screen).maxY + 24)
                        .opacity(isOpen && drag.height == 0 && isZoomed == false ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo.preview")
        .accessibilityAction(.escape) { close() }
        .task {
            measureAspects()
            // A turn after insertion, so the grow is its own transaction rather than riding the one
            // that put the overlay on screen.
            await Task.yield()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.open) { isOpen = true }
            await loadAspects()
        }
    }

    // MARK: - The page behind

    /// The page, blurred and dimmed — the system's material over an ink wash, so it reads in both modes.
    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(AteColor.ink.opacity(0.28))
    }

    private var backdropOpacity: Double {
        guard isOpen else { return 0 }
        return max(0, 1 - Double(max(0, drag.height)) / 420)
    }

    // MARK: - Geometry

    private var isZoomed: Bool { zoom * pinch > 1.01 }

    /// Where the photo at `position` rests.
    private func target(_ position: Int, _ screen: CGSize) -> CGRect {
        switch layout {
        case .whole:
            let maxWidth = screen.width - 2 * AteMetrics.cardGutter
            let maxHeight = screen.height * 0.74
            let aspect = aspects[position] ?? 0.8
            var width = maxWidth
            var height = width / aspect
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
            return CGRect(x: (screen.width - width) / 2, y: (screen.height - height) / 2 - 8,
                          width: width, height: height)
        case .peek:
            let width = (screen.width - 2 * AteMetrics.cardGutter) * 0.84
            let height = min(width * 1.25, screen.height * 0.66)
            return CGRect(x: (screen.width - width) / 2, y: (screen.height - height) / 2 - 20,
                          width: width, height: height)
        }
    }

    /// How far the next photo sits from this one.
    private func step(_ screen: CGSize) -> CGFloat {
        switch layout {
        case .whole: screen.width
        case .peek: target(index, screen).width + AteMetrics.regular
        }
    }

    // MARK: - The card

    private func card(_ position: Int, screen: CGSize) -> some View {
        let from = origin?.tiles[position]
        let rest = target(position, screen)
        let frame = isOpen ? rest : (from?.frame ?? rest)
        let horizontal = axis == .horizontal ? drag.width : 0
        let vertical = axis == .vertical && isZoomed == false ? drag.height : 0
        let dragScale = max(0.6, 1 - max(0, vertical) / 900)
        let scale = isOpen ? dragScale * zoom * pinch : (from == nil ? 0.9 : 1)
        let panned = isZoomed ? CGSize(width: pan.width + (axis == nil ? 0 : drag.width),
                                       height: pan.height + (axis == nil ? 0 : drag.height)) : .zero
        let radius = isOpen ? Self.cardRadius : (from?.radius ?? Self.cardRadius)
        return face(photos[position], size: frame.size, radius: radius)
            .rotationEffect(.degrees(isOpen ? 0 : (from?.angle ?? 0)))
            .scaleEffect(scale)
            .opacity(isOpen || from != nil ? 1 : 0)
            .position(x: frame.midX + horizontal + panned.width, y: frame.midY + vertical + panned.height)
            .gesture(dragGesture(screen))
            .simultaneousGesture(pinchGesture)
            .onTapGesture(count: 2) { toggleZoom() }
            .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
            .accessibilityAddTraits(.isImage)
    }

    private func face(_ photo: AtePhoto, size: CGSize, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return AtePhotoContent(photo: photo, size: .full)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .ateBackground(AteColor.ink, in: shape, shadow: .panel)
    }

    /// The photos either side — waiting just off the edges (A) or peeking in at them (B) — moving
    /// with the drag.
    private func neighbours(_ screen: CGSize) -> some View {
        let offsets = [index - 1, index + 1].filter(photos.indices.contains)
        let horizontal = axis == .horizontal ? drag.width : 0
        return ForEach(offsets, id: \.self) { position in
            let rest = target(position, screen)
            let shift = CGFloat(position - index) * step(screen)
            face(photos[position], size: rest.size, radius: Self.cardRadius)
                .scaleEffect(layout == .peek ? 0.92 : 1)
                .opacity(isOpen && isZoomed == false && drag.height <= 0 ? 1 : 0)
                .position(x: rest.midX + shift + horizontal, y: rest.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(photos.indices, id: \.self) { position in
                Circle()
                    .fill(Color.white.opacity(position == index ? 1 : 0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Gestures

    private func dragGesture(_ screen: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if isZoomed {
                    drag = value.translation
                } else if axis == .horizontal, photos.count < 2 {
                    // A single photo has nowhere to page to; the drag only resists.
                    drag = CGSize(width: value.translation.width / 4, height: 0)
                } else {
                    drag = value.translation
                }
            }
            .onEnded { value in
                if isZoomed {
                    pan = CGSize(width: pan.width + value.translation.width,
                                 height: pan.height + value.translation.height)
                    drag = .zero
                    axis = nil
                    return
                }
                switch axis {
                case .vertical:
                    if value.translation.height > Self.dismissDistance || value.predictedEndTranslation.height > 400 {
                        close()
                    } else {
                        withAnimation(Self.shut) { drag = .zero } completion: { axis = nil }
                    }
                case .horizontal:
                    page(by: value, screen: screen)
                case nil:
                    break
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in pinch = value.magnification }
            .onEnded { value in
                let settled = zoom * value.magnification
                pinch = 1
                zoom = settled
                if settled < 0.8 {
                    close()
                } else if settled <= 1 {
                    withAnimation(Self.shut) {
                        zoom = 1
                        pan = .zero
                    }
                } else {
                    withAnimation(Self.shut) { zoom = min(Self.maxZoom, settled) }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(reduceMotion ? nil : Self.shut) {
            if isZoomed {
                zoom = 1
                pan = .zero
            } else {
                zoom = 2.5
            }
        }
    }

    private func page(by value: DragGesture.Value, screen: CGSize) {
        let travelled = value.predictedEndTranslation.width
        let direction = abs(travelled) > Self.pageDistance ? (travelled < 0 ? 1 : -1) : 0
        let next = index + direction
        guard direction != 0, photos.indices.contains(next) else {
            withAnimation(Self.shut) { drag = .zero } completion: { axis = nil }
            return
        }
        withAnimation(reduceMotion ? nil : Self.shut) {
            drag = CGSize(width: CGFloat(-direction) * step(screen), height: 0)
        } completion: {
            index = next
            drag = .zero
            axis = nil
        }
    }

    private func close() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : Self.shut) {
            isOpen = false
            drag = .zero
            zoom = 1
            pinch = 1
            pan = .zero
        } completion: {
            onClose()
        }
    }

    // MARK: - Each photo's shape

    /// What is already decoded, at once — so the card opens at the right shape.
    private func measureAspects() {
        for (position, photo) in photos.enumerated() {
            if let url = photo.url, let image = AteImagePipeline.shared.bestCached(url, size: .full)?.image {
                aspects[position] = Self.aspect(image.size)
            }
        }
    }

    /// …and the rest as they arrive.
    private func loadAspects() async {
        guard layout == .whole else { return }
        for (position, photo) in photos.enumerated() where aspects[position] == nil {
            guard let url = photo.url,
                  let image = await AteImagePipeline.shared.image(url, size: .large) else { continue }
            withAnimation(reduceMotion ? nil : Self.shut) { aspects[position] = Self.aspect(image.size) }
        }
    }

    private static func aspect(_ size: CGSize) -> CGFloat? {
        guard size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}
