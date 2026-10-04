import AteKit
import SwiftUI

/// **Under an entry's paper, on the ground** (build 87, note 8): "More at <place>" — the place's best
/// dishes this entry did not log — and "More like this" — the dishes most like the entry's best one.
/// Kit shelves under kit headings. Nothing is drawn until both reads have answered; then the sections
/// with cards fade in together, in their final order. One with nothing (or whose read fell over) is
/// not on the page at all.
struct V2EntryMore: View {
    let store: EntryMoreStore
    /// The entry's place, for the heading and for what a card's page draws at once.
    let place: EntryCard.Place?
    let context: V2PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.showsPlace, let place {
                AteSectionHeading(title: "More at \(place.name)", identifier: "entry.more.place")
                placeShelf(place)
            }
            if store.showsSimilar {
                AteSectionHeading(title: "More like this", identifier: "entry.more.similar")
                similarShelf
            }
        }
        .ateAnimation(AteMotion.fillIn, value: store.isSettled)
    }

    private func placeShelf(_ place: EntryCard.Place) -> some View {
        let dishes = store.atPlace
        let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
        let cards = dishes.enumerated().map { index, dish in
            V2EntryMoreCard(position: index + 1, dish: dish, letter: letters[index])
        }
        return AteShelf(items: cards) { card in
            AteShelfCard(
                photo: .dish(card.letter, cover: card.dish.coverURLString),
                name: card.dish.name,
                score: card.dish.score.map(AteScore.average),
                onOpen: { open(card, at: place) }
            )
            .accessibilityIdentifier("entry.more.card")
        }
        .accessibilityIdentifier("entry.more.placeShelf")
    }

    private var similarShelf: some View {
        let dishes = store.similar
        let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
        let cards = dishes.enumerated().map { index, dish in
            V2EntryMoreCard(position: index + 1, dish: dish, letter: letters[index])
        }
        return AteShelf(items: cards) { card in
            AteShelfCard(
                photo: .dish(card.letter, cover: card.dish.coverURLString),
                name: card.dish.name,
                place: card.dish.restaurantName,
                score: card.dish.score.map(AteScore.average),
                onOpen: { open(card) }
            )
            .accessibilityIdentifier("entry.more.card")
        }
        .accessibilityIdentifier("entry.more.similarShelf")
    }

    private func open(_ card: V2EntryMoreCard<MenuDish>, at place: EntryCard.Place) {
        context.services.analytics(DetailEvents.entryMoreOpened(section: .place, position: card.position))
        // The card printed the dish, its score and its photo; the heading named the place.
        DishPreviews.shared.note(DishPreview(
            dishID: card.dish.dishID, name: card.dish.name,
            restaurantID: place.id, restaurantName: place.name,
            score: card.dish.score, photoURL: card.dish.coverURLString
        ))
        context.open(.dish(card.dish.dishID), from: .entryMore)
    }

    private func open(_ card: V2EntryMoreCard<SimilarDish>) {
        context.services.analytics(DetailEvents.entryMoreOpened(section: .similar, position: card.position))
        DishPreviews.shared.note(DishPreview(similar: card.dish))
        context.open(.dish(card.dish.dishID), from: .entryMore)
    }
}

/// One card on a shelf, with its place along it (1-based, for `entry_more_opened`).
private struct V2EntryMoreCard<Dish: Identifiable>: Identifiable where Dish.ID == UUID {
    let position: Int
    let dish: Dish
    let letter: DishLetter

    var id: UUID { dish.id }
}
