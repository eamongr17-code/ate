import AteKit
import SwiftUI

/// **Under a dish's reviews** (round 7): "More to explore" — the dish's tags as chips, each a door to
/// its own page of dishes — and "More like this", the dishes most like it on one shelf of the kit's
/// one card anatomy (contract §8), each a door to that dish.
///
/// Read after the page's own read and drawn once: until then each heading stands over still shapes
/// at its section's size. A section with nothing in it is not on the page at all.
struct V2DishExplore: View {
    let store: DishExploreStore
    let context: V2PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            if store.showsTags {
                heading("More to explore")
                Group {
                    if store.isSettled {
                        AteChipFlow(chips: store.tags.map(chip), isExplore: true)
                    } else {
                        AteChipFlowSkeleton(isExplore: true)
                    }
                }
                .padding(.horizontal, AteMetrics.listGutter)
                .transition(.opacity)
            }
            if store.showsSimilar {
                heading("More like this")
                shelf
            }
        }
        .padding(.top, AteMetrics.section)
        .ateAnimation(AteMotion.fillIn, value: store.isSettled)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .ateText(.exploreHeading)
            .foregroundStyle(AtePalette.automatic.fg)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, AteMetrics.snug)
            .padding(.horizontal, AteMetrics.listGutter)
    }

    private func chip(_ tag: DishTag) -> AteChipFlow.Chip {
        AteChipFlow.Chip(id: tag.id, title: tag.title) {
            context.services.analytics(DetailEvents.dishTagOpened(kind: tag.kind))
            context.open(.tag(DishTagRoute(tag)), from: .dish)
        }
    }

    @ViewBuilder
    private var shelf: some View {
        if store.isSettled {
            let letters = DishLetter.neighbourly(store.similar.map { ($0.dishID, $0.name) })
            let cards = store.similar.enumerated().map { index, dish in
                V2SimilarCard(position: index + 1, dish: dish, letter: letters[index])
            }
            AteShelf(items: cards) { card in
                AteShelfCard(
                    photo: .dish(card.letter, cover: card.dish.coverURLString),
                    name: card.dish.name,
                    place: card.dish.restaurantName,
                    score: card.dish.score.map(AteScore.average),
                    onOpen: { open(card) }
                )
                .accessibilityIdentifier("dish.explore.card")
            }
            .accessibilityIdentifier("dish.explore.similar")
            .transition(.opacity)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: AteShelfCardMetrics.spacing) {
                    ForEach(0..<V2DishExploreMetrics.skeletonCards, id: \.self) { _ in
                        AteSkeleton(kind: .shelfCard)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .contentMargins(.horizontal, AteMetrics.gutter, for: .scrollContent)
            .transition(.opacity)
        }
    }

    private func open(_ card: V2SimilarCard) {
        context.services.analytics(DetailEvents.similarDishOpened(position: card.position))
        // The card printed the dish, its place, its score and its photo: the page draws them at once.
        DishPreviews.shared.note(DishPreview(similar: card.dish))
        context.open(.dish(card.dish.dishID), from: .similar)
    }
}

/// One card on the shelf, with its place along it (1-based, for `similar_dish_opened`).
private struct V2SimilarCard: Identifiable {
    let position: Int
    let dish: SimilarDish
    let letter: DishLetter

    var id: UUID { dish.dishID }
}

enum V2DishExploreMetrics {
    static let skeletonCards = 3
}

extension DishPreview {
    /// What a "More like this" card or a tag's row printed — the aggregate included, because the row
    /// printed that very number.
    init(similar dish: SimilarDish) {
        self.init(
            dishID: dish.dishID,
            name: dish.name,
            restaurantID: dish.restaurantID,
            restaurantName: dish.restaurantName,
            score: dish.score,
            photoURL: dish.coverURLString
        )
    }
}
