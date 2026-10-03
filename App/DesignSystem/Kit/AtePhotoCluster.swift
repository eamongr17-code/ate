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
        /// The composer: 90.
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
    var onTap: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?

    var body: some View {
        let metrics = AtePhotoClusterMetrics(size)
        PhotoCluster(
            photos: photos,
            side: metrics.side,
            surface: surface,
            topPadding: metrics.top,
            bottomPadding: metrics.bottom,
            angles: metrics.angles,
            onRemove: onRemove,
            onTap: onTap
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
        case .composer: (side, angles, top, bottom) = (AteMetrics.clusterPhotoComposer, AtePhotoAngles.slip, 4, 2)
        case .summary: (side, angles, top, bottom) = (96, [-7, 5, -3], 0, 0)
        case .entry: (side, angles, top, bottom) = (104, [-6, 5, -2], 6, 0)
        }
    }
}
