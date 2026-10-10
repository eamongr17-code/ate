import AteKit
import SwiftUI

/// **"Your top dishes"** — up to four, side by side, each a 78pt photo (or its letter tile at the same
/// size and radius) with its name under it. Tilted as the build draws them (`-4 3 -3 4`, fixed per
/// position, never random), apart and **unringed**: they do not overlap, so they are not a cluster.
struct AteTopDishes: View {
    struct Dish: Identifiable, Equatable {
        /// The review's id: the same dish can be in the list twice.
        let id: UUID
        let dishID: UUID
        let name: String
        let photo: AtePhoto
    }

    let dishes: [Dish]
    var onOpen: (UUID) -> Void = { _ in }

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shown = Array(dishes.prefix(AteTopDishesMetrics.count))
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, dish in
                Button { onOpen(dish.dishID) } label: {
                    VStack(spacing: AteMetrics.snug) {
                        AteTopDishTile(photo: dish.photo)
                            .rotationEffect(.degrees(AteTopDishesMetrics.angles[index % AteTopDishesMetrics.count]))
                        AteExactText(
                            text: dish.name,
                            style: .tileCaption,
                            alignment: .center,
                            colour: palette.fg,
                            lineLimit: 2
                        )
                    }
                    .frame(width: AteTopDishesMetrics.column)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dish.name)
                .accessibilityIdentifier("you.topDish")
                if index < shown.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One top-dish photo: straight-edged squircle, its letter tile when there is no photo.
struct AteTopDishTile: View {
    let photo: AtePhoto

    var body: some View {
        let side = AteTopDishesMetrics.side
        Color.clear
            .frame(width: side, height: side)
            .overlay {
                if photo.image != nil || photo.url != nil {
                    AtePhotoContent(photo: photo, size: .forSide(side))
                } else if let dish = photo.dish {
                    AteLetterTile(dish: dish, initial: AteTopDishesMetrics.initial)
                } else {
                    AtePhotoContent(photo: photo)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Four still tiles, breathing, where the top dishes will be.
struct AteTopDishesSkeleton: View {
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<AteTopDishesMetrics.count, id: \.self) { index in
                RoundedRectangle(
                    cornerRadius: AteMetrics.photoRadius(side: AteTopDishesMetrics.side),
                    style: .continuous
                )
                .fill(palette.hairline)
                .frame(width: AteTopDishesMetrics.side, height: AteTopDishesMetrics.side)
                .frame(width: AteTopDishesMetrics.column)
                if index < AteTopDishesMetrics.count - 1 { Spacer(minLength: 0) }
            }
        }
        .ateSkeletonSweep(breathes)
        .accessibilityHidden(true)
    }
}

enum AteTopDishesMetrics {
    static let count = 4
    /// `width:80px` per column, a 78pt photo in it.
    static let column: CGFloat = 80
    static let side: CGFloat = 78
    static let initial: CGFloat = 34
    /// Fixed per position: the same four dishes look the same every time the tab opens.
    static let angles: [Double] = [-4, 3, -3, 4]
}
