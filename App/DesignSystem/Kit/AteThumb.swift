import AteKit
import SwiftUI

/// **A dish thumbnail — one component.** The dish's photo, or, with none, its letter tile: the same
/// size and the same radius in the same list, so a tile never reads as a different kind of thing
/// from the photo beside it. Straight, and **never ringed** — the 3pt ring belongs to a tilted
/// cluster alone (``AtePhotoCluster``). Never an empty grey square.
struct AteThumb: View {
    /// The slots a dish thumbnail comes in.
    enum Size: Equatable {
        /// A dish row and a ranked row: 56, radius 16 (`.srow .thumb`).
        case row
        /// A place's menu: 48, radius 14 (`.mrow .thumb`).
        case menu
        /// A shelf card: 168 × 210, radius 16 (`.card .p`).
        case card
        /// The hero: the column's width × 330, radius 16 (`.hero`).
        case hero
    }

    /// A dish's photo (``AtePhoto/dish(_:cover:)``) — a cover, or the letter it falls back to.
    let photo: AtePhoto
    var size: Size = .row

    var body: some View {
        let metrics = AteThumbMetrics(size)
        content(metrics)
            .frame(width: metrics.width, height: metrics.height)
            .frame(maxWidth: metrics.width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ metrics: AteThumbMetrics) -> some View {
        if photo.image != nil || photo.url != nil {
            AtePhotoContent(photo: photo, size: .forSide(metrics.height))
        } else if let dish = photo.dish {
            AteLetterTile(dish: dish, initial: metrics.initial)
        } else {
            AtePhotoContent(photo: photo)
        }
    }
}

/// **The letter tile**: the slot filled with the dish's own accent (never butter, which means a
/// score), its first letter in Bricolage 800, ink. Neighbours in a list never share an accent
/// (``DishLetter/neighbourly(_:)``).
struct AteLetterTile: View {
    let dish: DishLetter
    let initial: CGFloat

    var body: some View {
        Text(dish.letter)
            .ateText(.kitThumbInitial(initial))
            .foregroundStyle(AteColor.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dish.accent)
            .accessibilityHidden(true)
    }
}

/// Each slot's numbers.
struct AteThumbMetrics {
    /// `nil` takes the column's width.
    let width: CGFloat?
    let height: CGFloat
    let radius: CGFloat
    /// The letter's size on a tile.
    let initial: CGFloat

    init(_ size: AteThumb.Size) {
        switch size {
        case .row: (width, height, radius, initial) = (56, 56, 16, 26)
        case .menu: (width, height, radius, initial) = (48, 48, 14, 22)
        case .card: (width, height, radius, initial) = (168, 210, 16, 64)
        case .hero: (width, height, radius, initial) = (nil, 330, 16, 120)
        }
    }
}
