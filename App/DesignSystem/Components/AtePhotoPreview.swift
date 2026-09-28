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
        /// The `.zoom` transition's source.
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
    /// The namespace the viewer's `.zoom` sources are matched in.
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
    /// and it is the `.zoom` transition's source.
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
