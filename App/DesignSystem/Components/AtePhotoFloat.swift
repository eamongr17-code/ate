import AteKit
import SwiftUI

/// **A photo, floating over the page it was tapped on** (round 5, Eamon: "the image should show up
/// above a blurred-out screen"; he picked B, the card with its neighbours peeking). The page stays
/// where it is, blurred and dimmed; the photo grows out of the tile it was tapped on into a 4:5
/// card a little narrower than the screen, the entry's other photos peeking in at its edges and a
/// row of dots under it.
///
/// - Swipe sideways for the entry's other photos.
/// - Pinch to zoom (the card grows over the blur), drag to look around while zoomed, double-tap to
///   zoom in or back out; pinching it well below its resting size puts it away.
/// - Swipe down, or tap the blurred page, and it shrinks back into its tile.
///
/// With Reduce Motion it fades in and out rather than growing and shrinking.
struct AtePhotoFloat: View {
    let photos: [AtePhoto]
    let origin: AtePhotoOrigin?
    let onClose: () -> Void

    @State private var index: Int
    @State private var isOpen = false
    @State private var drag: CGSize = .zero
    @State private var axis: Axis?
    /// The zoom at rest, and the pinch in progress on top of it.
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    /// Where a zoomed photo has been dragged to.
    @State private var pan: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(photos: [AtePhoto], index: Int, origin: AtePhotoOrigin?, onClose: @escaping () -> Void) {
        self.photos = photos
        self.origin = origin
        self.onClose = onClose
        _index = State(initialValue: index)
    }

    private static let dismissDistance: CGFloat = 110
    private static let pageDistance: CGFloat = 80
    /// The card's corner — a photo's squircle at the size it is drawn.
    private static let cardRadius: CGFloat = 28
    /// The card's share of the card width: what leaves room for the neighbours to peek.
    private static let cardShare: CGFloat = 0.84
    /// The neighbours sit a touch smaller, so the one in front reads as in front.
    private static let neighbourScale: CGFloat = 0.92
    private static let maxZoom: CGFloat = 4
    private static let dotSide: CGFloat = 6
    private static let open = Animation.spring(duration: 0.42, bounce: 0.16)
    private static let shut = Animation.spring(duration: 0.34, bounce: 0.06)

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            let rest = target(screen)
            ZStack(alignment: .topLeading) {
                backdrop
                    .opacity(backdropOpacity)
                    .contentShape(.rect)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                neighbours(rest)
                card(rest, screen: screen)
                if photos.count > 1 {
                    dots
                        .position(x: screen.width / 2, y: rest.maxY + AteMetrics.section)
                        .opacity(isOpen && drag.height == 0 && isZoomed == false ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("photo.preview")
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(named: Text("Close")) { close() }
        .task {
            // A turn after insertion, so the grow is its own transaction rather than riding the one
            // that put the overlay on screen.
            await Task.yield()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.open) { isOpen = true }
        }
    }

    // MARK: - The page behind

    /// The page, blurred and dimmed — the system's material under an ink wash, in both modes.
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

    /// Where the photo rests: 4:5, centred a touch above the middle.
    private func target(_ screen: CGSize) -> CGRect {
        let width = (screen.width - 2 * AteMetrics.cardGutter) * Self.cardShare
        let height = min(width * 1.25, screen.height * 0.66)
        return CGRect(x: (screen.width - width) / 2, y: (screen.height - height) / 2 - 20,
                      width: width, height: height)
    }

    /// How far the next photo sits from this one.
    private func step(_ rest: CGRect) -> CGFloat { rest.width + AteMetrics.regular }

    // MARK: - The card

    private func card(_ rest: CGRect, screen: CGSize) -> some View {
        let from = origin?.tiles[index]
        let frame = isOpen ? rest : (from?.frame ?? rest)
        let horizontal = axis == .horizontal && isZoomed == false ? drag.width : 0
        let vertical = axis == .vertical && isZoomed == false ? drag.height : 0
        let dragScale = max(0.6, 1 - max(0, vertical) / 900)
        let scale = isOpen ? dragScale * zoom * pinch : (from == nil ? 0.9 : 1)
        let travelled = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        let panned = isZoomed ? clamped(travelled, rest: rest, screen: screen) : .zero
        let radius = isOpen ? Self.cardRadius : (from?.radius ?? Self.cardRadius)
        return face(photos[index], size: frame.size, radius: radius)
            .rotationEffect(.degrees(isOpen ? 0 : (from?.angle ?? 0)))
            .scaleEffect(scale)
            .opacity(isOpen || from != nil ? 1 : 0)
            .position(x: frame.midX + horizontal + panned.width, y: frame.midY + vertical + panned.height)
            .gesture(dragGesture(rest, screen: screen))
            .simultaneousGesture(pinchGesture)
            .onTapGesture(count: 2) { toggleZoom() }
            .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("photo.preview.card")
            // VoiceOver: swipe up or down on the photo to page through the entry's photos, and the
            // Close action (or the escape scrub) to put it away.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(to: index + 1)
                case .decrement: step(to: index - 1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Close")) { close() }
    }

    private func face(_ photo: AtePhoto, size: CGSize, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return AtePhotoContent(photo: photo, size: .full)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .ateBackground(AteColor.ink, in: shape, shadow: .panel)
    }

    /// The photos either side, peeking in at the edges and moving with the drag.
    private func neighbours(_ rest: CGRect) -> some View {
        let horizontal = axis == .horizontal ? drag.width : 0
        return ForEach([index - 1, index + 1].filter(photos.indices.contains), id: \.self) { position in
            face(photos[position], size: rest.size, radius: Self.cardRadius)
                .scaleEffect(Self.neighbourScale)
                .opacity(isOpen && isZoomed == false && drag.height <= 0 ? 1 : 0)
                .position(x: rest.midX + CGFloat(position - index) * step(rest) + horizontal, y: rest.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var dots: some View {
        HStack(spacing: Self.dotSide) {
            ForEach(photos.indices, id: \.self) { position in
                Circle()
                    .fill(AteColor.overPhoto.opacity(position == index ? 1 : 0.45))
                    .frame(width: Self.dotSide, height: Self.dotSide)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Gestures

    private func dragGesture(_ rest: CGRect, screen: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if isZoomed == false, axis == .horizontal, photos.count < 2 {
                    // A single photo has nowhere to page to; the drag only resists.
                    drag = CGSize(width: value.translation.width / 4, height: 0)
                } else {
                    drag = value.translation
                }
            }
            .onEnded { value in
                if isZoomed {
                    let travelled = CGSize(width: pan.width + value.translation.width,
                                           height: pan.height + value.translation.height)
                    pan = clamped(travelled, rest: rest, screen: screen)
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
                    page(by: value, rest: rest)
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

    /// A zoomed photo pans only as far as it overhangs the screen, so an edge can be brought into
    /// view but the photo can never be dragged off it. Re-clamped as it is drawn, so zooming back
    /// out pulls it home.
    private func clamped(_ offset: CGSize, rest: CGRect, screen: CGSize) -> CGSize {
        let scale = zoom * pinch
        let spareX = max(0, (rest.width * scale - screen.width) / 2 + abs(rest.midX - screen.width / 2))
        let spareY = max(0, (rest.height * scale - screen.height) / 2 + abs(rest.midY - screen.height / 2))
        return CGSize(width: min(spareX, max(-spareX, offset.width)),
                      height: min(spareY, max(-spareY, offset.height)))
    }

    /// Pages without a drag — VoiceOver's adjustable action.
    private func step(to next: Int) {
        guard photos.indices.contains(next) else { return }
        withAnimation(reduceMotion ? nil : Self.shut) {
            index = next
            zoom = 1
            pan = .zero
        }
    }

    private func page(by value: DragGesture.Value, rest: CGRect) {
        let travelled = value.predictedEndTranslation.width
        let direction = abs(travelled) > Self.pageDistance ? (travelled < 0 ? 1 : -1) : 0
        let next = index + direction
        guard direction != 0, photos.indices.contains(next) else {
            withAnimation(Self.shut) { drag = .zero } completion: { axis = nil }
            return
        }
        withAnimation(reduceMotion ? nil : Self.shut) {
            drag = CGSize(width: CGFloat(-direction) * step(rest), height: 0)
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
}
