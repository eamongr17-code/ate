import AteKit
import SwiftUI

/// **A place on the dish map** (`nearby-map.html`, option A, approved 25 Oct): its best dish's photo
/// in the photo squircle, with **one badge, the score**, on top and centred under the photo, with no
/// ring, only a soft shadow (`nearby-map-2.html`, B). A place with more dishes shows one more photo
/// stacked behind, up and to the right — two photos at most, and never over the score. Selected, the
/// pin grows and the two photos fan apart; no outline.
struct AteMapPin: View {
    let front: AtePhoto
    /// The next dish's photo, stacked behind. `nil` for a place with one dish (or one photo).
    let behind: AtePhoto?
    /// The best dish's average. `nil` when nobody scored it: no badge, never an inferred one.
    let score: Double?
    var isSelected = false

    var body: some View {
        let ring = AteColor.slip
        ZStack {
            if let behind {
                tile(behind, ring: ring)
                    .rotationEffect(.degrees(isSelected ? AteMapPinMetrics.fannedTilt : AteMapPinMetrics.stackTilt))
                    .offset(isSelected ? AteMapPinMetrics.fannedOffset : AteMapPinMetrics.stackOffset)
            }
            tile(front, ring: ring)
                .rotationEffect(.degrees(isSelected ? AteMapPinMetrics.frontFannedTilt : 0))
            if let score {
                AteScoreToken(average: score)
                    .ateShadow(.mapScore)
                    .offset(y: AteMapPinMetrics.side / 2)
            }
        }
        .scaleEffect(isSelected ? AteMapPinMetrics.selectedScale : 1)
        .ateAnimation(AteMotion.pinFan, value: isSelected)
    }

    private func tile(_ photo: AtePhoto, ring: Color) -> some View {
        AtePhotoTile(photo: photo, side: AteMapPinMetrics.side, ring: ring)
            .ateShadow(.mapPin)
    }
}

/// **Places the photos had no room for** (`nearby-map-2.html` "Zooming"): a small dot, butter when
/// a place in it has a score and the field when none has (butter means a score). One dot can hold
/// several places close together, and is a little bigger the more it holds (1, 2–4, 5+). Tappable:
/// one place grows into its photos; several zoom the map in.
struct AteMapDot: View {
    let isScored: Bool
    var count = 1

    @Environment(\.atePalette) private var palette

    var body: some View {
        let side = AteMapPinMetrics.dot(holding: count)
        Circle()
            .fill(isScored ? AteColor.scoreFill : palette.field)
            .frame(width: side, height: side)
            .background(Circle().fill(AteColor.slip).padding(-AteMapPinMetrics.dotRing))
            .ateShadow(.mapDot)
            // The dot is small; the finger is not.
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
            .contentShape(Rectangle())
    }
}

enum AteMapPinMetrics {
    /// The photo: 48, radius 13 (28%, the photo squircle).
    static let side: CGFloat = 48
    /// The photo behind, at rest: up and to the right, so the score below stays clear.
    static let stackOffset = CGSize(width: 7, height: -7)
    static let stackTilt: Double = 6
    /// Selected: the one behind swings out to the right, the front one tips left.
    static let fannedOffset = CGSize(width: 17, height: -3)
    static let fannedTilt: Double = 11
    static let frontFannedTilt: Double = -5
    static let selectedScale: CGFloat = 1.3
    /// A dot's side: one place, two to four, five or more.
    static func dot(holding count: Int) -> CGFloat {
        switch count {
        case ...1: 13
        case 2...4: 17
        default: 21
        }
    }
    static let dotRing: CGFloat = 2
}
