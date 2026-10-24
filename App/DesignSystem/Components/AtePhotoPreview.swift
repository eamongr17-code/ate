import AteKit
import SwiftUI

// MARK: - Where a photo opens from

/// Where each photo of a cluster sits on the page when one is tapped — what a preview grows from
/// and shrinks back into. Keyed by the photo's index in the list handed to the viewer.
struct AtePhotoOrigin: Sendable {
    struct Tile: Sendable {
        /// In window coordinates.
        var frame: CGRect
        var radius: CGFloat
        var angle: Double
        /// The ring round it, in its surface's colour, when its cluster laps photos.
        var ring: Color?
        /// The part of the picture the tile crops onto (a dish page's focus), else its middle.
        var focus: PhotoDishBox?
        /// Its place in the cluster's stack: 0 on top, each next one under the one before.
        var layer: Int
        /// Names the tile, so it can step aside while its photo is up.
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
    /// The tile the open viewer's photo came from and goes back to, hidden meanwhile so the photo
    /// is never on the page twice.
    @Entry var atePhotoHiddenSource: String?
}

/// The tiles of one cluster, measured as they lay out — held in a box rather than state, because a
/// frame moving on every scroll must never redraw the cluster.
@MainActor
final class AtePhotoTileFrames {
    let key = UUID().uuidString
    var frames: [Int: CGRect] = [:]

    func sourceID(_ index: Int) -> String { "\(key).\(index)" }

    // swiftlint:disable function_parameter_count
    /// `side`: the tiles' own size, laid out — a tilted tile measures as its bounding box, which
    /// would land the photo a size too big.
    func origin(
        side: CGFloat, radius: (Int) -> CGFloat, angle: (Int) -> Double, ring: Color?,
        focus: (Int) -> PhotoDishBox?, layer: (Int) -> Int
    ) -> AtePhotoOrigin {
        AtePhotoOrigin(tiles: Dictionary(uniqueKeysWithValues: frames.map { index, frame in
            let square = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
            return (index, AtePhotoOrigin.Tile(frame: square, radius: radius(index), angle: angle(index),
                                               ring: ring, focus: focus(index), layer: layer(index),
                                               sourceID: sourceID(index)))
        }))
    }
    // swiftlint:enable function_parameter_count
}

extension View {
    /// Marks a photo tile as something a preview grows from: its frame is measured into `frames`,
    /// and the photo lands back on it.
    func atePhotoSource(_ frames: AtePhotoTileFrames, index: Int, radius: CGFloat) -> some View {
        modifier(AtePhotoSourceModifier(frames: frames, index: index, radius: radius))
    }
}

private struct AtePhotoSourceModifier: ViewModifier {
    let frames: AtePhotoTileFrames
    let index: Int
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                frames.frames[index] = frame
            }
    }
}
