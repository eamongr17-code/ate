import SwiftUI

/// **The mess** — photos tilted and overlapping in a small static cluster, the one place the 3pt
/// surface ring appears (it parts each photo from the one it laps). Only on entry slips, the entry,
/// the dish hero, Share and Welcome; every list elsewhere is straight (``AteThumb``). A cluster sits
/// clear of a receipt, never over it.
///
/// The existing ``PhotoCluster`` with its sizes named: each is a screen's own side, tilt and air.
struct AtePhotoCluster: View {
    enum Size: Equatable {
        /// An entry slip: 80, `-5 4 -2`, `padding:2px 0 0 6px`.
        case slip
        /// The composer: 116 (Eamon, 7 Oct: "a bit bigger").
        case composer
        /// The printed receipt's stage: 96, `-7 5 -3`.
        case summary
        /// The entry page: 104, `-6 5 -2`.
        case entry
    }

    let photos: [AtePhoto]
    var size: Size = .slip
    /// The colour directly behind the cluster — the ring is drawn in it. Defaults to the surface.
    var surface: Color?
    /// A tapped photo. Unset, a photo opens the viewer on these photos — every cluster is a door to
    /// the viewer, the composer's too (its X is the way to take one out).
    var onTap: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?

    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        let metrics = AtePhotoClusterMetrics(size)
        let photos = photos
        let showPhotos = showPhotos
        PhotoCluster(
            photos: photos,
            side: metrics.side,
            surface: surface,
            topPadding: metrics.top,
            bottomPadding: metrics.bottom,
            angles: metrics.angles,
            onRemove: onRemove,
            onTap: onTap ?? { showPhotos(photos, at: $0) }
        )
    }
}

struct AtePhotoClusterMetrics {
    let side: CGFloat
    let angles: [Double]
    let top: CGFloat
    let bottom: CGFloat

    init(_ size: AtePhotoCluster.Size) {
        switch size {
        case .slip: (side, angles, top, bottom) = (AteMetrics.clusterPhoto, AtePhotoAngles.slip, 2, 0)
        // The tilt carries a corner ~5 past the square at 116: the air above and below covers it.
        case .composer: (side, angles, top, bottom) = (AteMetrics.clusterPhotoComposer, AtePhotoAngles.slip, 8, 6)
        case .summary: (side, angles, top, bottom) = (96, [-7, 5, -3], 0, 0)
        case .entry: (side, angles, top, bottom) = (104, [-6, 5, -2], 6, 0)
        }
    }
}
