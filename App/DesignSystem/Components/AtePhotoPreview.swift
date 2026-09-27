import AteKit
import SwiftUI

// MARK: - The exploration

/// **How a tapped photo opens** — round 4's exploration, picked with `-ate-photo-preview A|B|C`.
/// Every option swipes between an entry's photos and swipes down to put the photo back. One
/// component, hosted once by the shell: every caller of ``AtePhotoViewerAction`` — slips, the entry
/// page, the dish and place pages — gets the same one, with no change at the call site.
enum AtePhotoPreviewStyle: String, Sendable {
    /// Today's full-screen black viewer. The default until Eamon picks.
    case viewer = ""
    /// **A** — the photo grows out of its thumbnail into a large rounded card floating over the page,
    /// which dims and blurs behind it.
    case card = "A"
    /// **B** — the system's own `.zoom` transition into the full-screen viewer.
    case zoom = "B"
    /// **C** — the prints: the photo lifts off the page like a print picked up off the table, still
    /// on its white border, with the entry's other photos fanned tilted behind it. Swiping deals the
    /// next one to the top. The brand's "mess" (tilt and overlap), used for looking.
    case prints = "C"

    var telemetryName: String {
        switch self {
        case .viewer: "viewer"
        case .card: "A"
        case .zoom: "B"
        case .prints: "C"
        }
    }
}

/// Where each photo of a cluster sits on the page when one is tapped — what a preview grows from
/// and shrinks back into. Keyed by the photo's index in the list handed to the viewer.
struct AtePhotoOrigin: Sendable {
    struct Tile: Sendable {
        /// In window coordinates.
        var frame: CGRect
        var radius: CGFloat
        var angle: Double
        /// The `.zoom` transition's source (B).
        var sourceID: String
    }

    var tiles: [Int: Tile]
}

/// Carries a tapped cluster's tiles to the host in the same turn as the tap, so no caller of the
/// viewer has to pass them — `showPhotos(photos, at:)` stays the whole API.
@MainActor
final class AtePhotoOriginRelay {
    private var pending: AtePhotoOrigin?

    func note(_ origin: AtePhotoOrigin) { pending = origin }

    func take() -> AtePhotoOrigin? {
        defer { pending = nil }
        return pending
    }
}

extension EnvironmentValues {
    @Entry var atePhotoOriginRelay: AtePhotoOriginRelay?
    /// Present only under the native zoom (B): the namespace its sources are matched in.
    @Entry var atePhotoZoomNamespace: Namespace.ID?
}

/// The tiles of one cluster, measured as they lay out — held in a box rather than state, because a
/// frame moving on every scroll must never redraw the cluster.
@MainActor
final class AtePhotoTileFrames {
    let key = UUID().uuidString
    var frames: [Int: CGRect] = [:]

    func sourceID(_ index: Int) -> String { "\(key).\(index)" }

    func origin(radius: (Int) -> CGFloat, angle: (Int) -> Double) -> AtePhotoOrigin {
        AtePhotoOrigin(tiles: Dictionary(uniqueKeysWithValues: frames.map { index, frame in
            (index, AtePhotoOrigin.Tile(frame: frame, radius: radius(index), angle: angle(index),
                                        sourceID: sourceID(index)))
        }))
    }
}

extension View {
    /// Marks a photo tile as something a preview grows from: its frame is measured into `frames`,
    /// and under the native zoom it is the transition's source.
    func atePhotoSource(_ frames: AtePhotoTileFrames, index: Int) -> some View {
        modifier(AtePhotoSourceModifier(frames: frames, index: index))
    }
}

private struct AtePhotoSourceModifier: ViewModifier {
    let frames: AtePhotoTileFrames
    let index: Int
    @Environment(\.atePhotoZoomNamespace) private var zoom

    func body(content: Content) -> some View {
        let measured = content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            frames.frames[index] = frame
        }
        if let zoom {
            measured.matchedTransitionSource(id: frames.sourceID(index), in: zoom)
        } else {
            measured
        }
    }
}

// MARK: - A and C: the lift

/// **The photo, lifted over the page it was on** — options A and C.
///
/// Grows from the tapped tile (its frame, corner and tilt) to a large card in the middle of the
/// screen, over the page dimmed behind it. Swipe sideways for the entry's other photos, swipe down —
/// or tap the page — to shrink it back into the tile it came from. With Reduce Motion it fades.
struct AtePhotoLift: View {
    enum Treatment {
        /// A: a large rounded card, the page dimmed and blurred.
        case card
        /// C: a print on its white border, the others fanned behind it, on the ground.
        case prints
    }

    let photos: [AtePhoto]
    @State var index: Int
    let origin: AtePhotoOrigin?
    let treatment: Treatment
    let onClose: () -> Void

    @State private var isOpen = false
    @State private var drag: CGSize = .zero
    @State private var axis: Axis?
    /// C: how far the top print has been thrown, as it leaves for the back of the deck.
    @State private var dealt: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atePalette) private var palette

    init(photos: [AtePhoto], index: Int, origin: AtePhotoOrigin?, treatment: Treatment, onClose: @escaping () -> Void) {
        self.photos = photos
        _index = State(initialValue: index)
        self.origin = origin
        self.treatment = treatment
        self.onClose = onClose
    }

    /// A dismissing drag, how far before letting go puts it back.
    private static let dismissDistance: CGFloat = 110
    private static let pageDistance: CGFloat = 80
    /// The card's corner at rest — a photo's squircle, at the size it is drawn (A); a print's (C).
    private static let cardRadius: CGFloat = 28
    private static let printBorder: CGFloat = 8
    private static let open = Animation.spring(duration: 0.42, bounce: 0.18)
    private static let shut = Animation.spring(duration: 0.36, bounce: 0.08)

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            let target = targetFrame(in: screen)
            ZStack(alignment: .topLeading) {
                backdrop
                    .opacity(backdropOpacity)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                if treatment == .prints { deck(target: target) }
                if treatment == .card { neighbours(target: target) }
                card(index, target: target)
                    .gesture(dragGesture(width: screen.width))
                if treatment == .card, photos.count > 1 {
                    dots
                        .position(x: screen.width / 2, y: target.maxY + 22)
                        .opacity(isOpen && drag.height == 0 ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo.preview")
        .accessibilityAction(.escape) { close() }
        .task {
            // A turn after insertion, so the grow is its own transaction rather than riding (and
            // being cut short by) the one that put the overlay on screen.
            await Task.yield()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.open) { isOpen = true }
        }
    }

    // MARK: Geometry

    /// Where the photo rests: the one card width across (A) or a little narrower, as a print held up
    /// (C), 4:5, centred a touch above the middle.
    private func targetFrame(in screen: CGSize) -> CGRect {
        let width = treatment == .card
            ? screen.width - 2 * AteMetrics.cardGutter
            : (screen.width - 2 * AteMetrics.cardGutter) * 0.86
        let height = min(width * 1.25, screen.height * 0.68)
        return CGRect(x: (screen.width - width) / 2, y: (screen.height - height) / 2 - 16, width: width, height: height)
    }

    /// The tile the photo at `position` came from, when the page has one.
    private func tile(_ position: Int) -> AtePhotoOrigin.Tile? { origin?.tiles[position] }

    private var backdropOpacity: Double {
        guard isOpen else { return 0 }
        return max(0, 1 - Double(max(0, drag.height)) / 420)
    }

    @ViewBuilder
    private var backdrop: some View {
        switch treatment {
        case .card:
            // The page stays there, dimmed and blurred: the glass material over an ink wash.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(AteColor.ink.opacity(0.28))
        case .prints:
            palette.ground.opacity(0.94)
        }
    }

    // MARK: The card

    private func card(_ position: Int, target: CGRect) -> some View {
        let from = tile(position)
        // Closed and with no tile to go back to, it shrinks in place and fades.
        let rest = isOpen ? target : (from?.frame ?? target)
        let dragScale = max(0.6, 1 - max(0, drag.height) / 900)
        let horizontal = axis == .horizontal ? drag.width : 0
        let vertical = axis == .vertical ? drag.height : 0
        let radius = isOpen ? radiusAtRest : (from?.radius ?? radiusAtRest)
        let angle = isOpen ? restingAngle(position) + Double(dealt / 30) : (from?.angle ?? 0)
        return photoFace(photos[position], size: rest.size, radius: radius)
            .rotationEffect(.degrees(angle + (treatment == .prints ? Double(horizontal / 24) : 0)))
            .scaleEffect(isOpen ? dragScale : (from == nil ? 0.9 : 1))
            .opacity(isOpen || from != nil ? 1 : 0)
            .position(x: rest.midX + horizontal + dealt, y: rest.midY + vertical)
            .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
            .accessibilityAddTraits(.isImage)
    }

    private var radiusAtRest: CGFloat {
        treatment == .card ? Self.cardRadius : AteMetrics.photoRadius(side: 90)
    }

    /// C keeps a print's tilt even held up; A lies flat.
    private func restingAngle(_ position: Int) -> Double {
        treatment == .prints ? AtePhotoAngles.slip[position % AtePhotoAngles.slip.count] * 0.4 : 0
    }

    @ViewBuilder
    private func photoFace(_ photo: AtePhoto, size: CGSize, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let face = AtePhotoContent(photo: photo, size: .large)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
        switch treatment {
        case .card:
            face.ateBackground(AteColor.ink, in: shape, shadow: .panel)
        case .prints:
            // A print: the photo on its white border, the paper's own contact line under it.
            let paper = RoundedRectangle(cornerRadius: radius + Self.printBorder, style: .continuous)
            face
                .padding(Self.printBorder)
                .ateBackground(AtePaperTone.slip.ring, in: paper, shadow: .panel)
        }
    }

    /// A: the next and the last photo, waiting either side and sliding in with the drag.
    @ViewBuilder
    private func neighbours(target: CGRect) -> some View {
        if isOpen, axis == .horizontal {
            ForEach([index - 1, index + 1].filter(photos.indices.contains), id: \.self) { position in
                let offset = CGFloat(position - index) * (target.width + AteMetrics.loose)
                photoFace(photos[position], size: target.size, radius: Self.cardRadius)
                    .position(x: target.midX + offset + drag.width, y: target.midY)
            }
        }
    }

    /// C: up to two more prints fanned behind the top one.
    @ViewBuilder
    private func deck(target: CGRect) -> some View {
        let behind = (1..<min(3, photos.count)).map { (index + $0) % photos.count }.reversed()
        ForEach(Array(behind), id: \.self) { position in
            let depth = CGFloat((position - index + photos.count) % photos.count)
            photoFace(photos[position], size: target.size, radius: radiusAtRest)
                .rotationEffect(.degrees(depth == 1 ? 5 : -6))
                .scaleEffect(1 - depth * 0.04)
                .position(x: target.midX + depth * 10, y: target.midY + depth * 6)
                .opacity(isOpen && drag.height == 0 ? 1 : 0)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(photos.indices, id: \.self) { position in
                Circle()
                    .fill(AteColor.slip.opacity(position == index ? 1 : 0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Gestures

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                // A single photo has nowhere to page to; the drag only resists.
                if axis == .horizontal, photos.count < 2 {
                    drag = CGSize(width: value.translation.width / 4, height: 0)
                } else {
                    drag = value.translation
                }
            }
            .onEnded { value in
                let finished = axis
                axis = finished
                switch finished {
                case .vertical:
                    if value.translation.height > Self.dismissDistance || value.predictedEndTranslation.height > 400 {
                        close()
                    } else {
                        withAnimation(Self.shut) { drag = .zero }
                        axis = nil
                    }
                case .horizontal:
                    page(by: value, width: width)
                case nil:
                    axis = nil
                }
            }
    }

    private func page(by value: DragGesture.Value, width: CGFloat) {
        let travelled = value.predictedEndTranslation.width
        let step = abs(travelled) > Self.pageDistance ? (travelled < 0 ? 1 : -1) : 0
        let next = index + step
        guard step != 0, photos.count > 1 else {
            withAnimation(Self.shut) { drag = .zero } completion: { axis = nil }
            return
        }
        switch treatment {
        case .card:
            guard photos.indices.contains(next) else {
                withAnimation(Self.shut) { drag = .zero } completion: { axis = nil }
                return
            }
            withAnimation(reduceMotion ? nil : Self.shut) {
                drag = CGSize(width: CGFloat(-step) * (width - 2 * AteMetrics.cardGutter + AteMetrics.loose), height: 0)
            } completion: {
                index = next
                drag = .zero
                axis = nil
            }
        case .prints:
            // The top print is thrown off to the side it was swiped, and the next is dealt on top.
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) {
                dealt = CGFloat(-step) * width
                drag = .zero
            } completion: {
                index = (index + step + photos.count) % photos.count
                dealt = 0
                axis = nil
            }
        }
    }

    private func close() {
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.18) : Self.shut
        withAnimation(animation) {
            isOpen = false
            drag = .zero
            dealt = 0
        } completion: {
            onClose()
        }
    }
}
