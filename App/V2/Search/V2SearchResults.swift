import AteKit
import SwiftUI

/// **Search's answers**, one scope at a time, as the kit's rows: a place (pin, place and suburb on
/// one line, its average), a dish (straight thumbnail or letter tile, the place under it, the score
/// token — an empty slot when nobody scored it), a person (avatar, handle, name), and a saved dish
/// with its bookmark. Six from the end, the next page is asked for.
struct V2SearchResults: View {
    let store: SearchStore
    let recents: RecentSearches
    let app: AppModel
    let open: (Route) -> Void

    var body: some View {
        switch store.rows {
        case .places(let places):
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                AtePlaceRow(
                    name: place.name,
                    suburb: place.locality,
                    score: place.score.map(AteScore.average),
                    isFirst: index == 0
                ) {
                    PlacePreviews.shared.note(place.restaurantID, name: place.name)
                    open(.place(place.restaurantID))
                }
                .task { await store.loadMoreIfNeeded(index: index) }
            }
        case .dishes(let dishes):
            let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
            ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                AteDishRow(
                    photo: .dish(letters[index], cover: dish.coverURLString),
                    name: dish.name,
                    tags: dish.tags,
                    subtitle: dish.restaurantName,
                    score: dish.score.map(AteScore.average),
                    isFirst: index == 0,
                    onOpen: { openDish(dish) }
                )
                .accessibilityIdentifier("search.dish")
                .task { await store.loadMoreIfNeeded(index: index) }
            }
        case .people(let people):
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                AtePersonRow(userID: person.userID, handle: person.handle, name: person.name, isFirst: index == 0) {
                    open(.profile(person.userID))
                }
                .task { await store.loadMoreIfNeeded(index: index) }
            }
        case .saved(let saved):
            let letters = DishLetter.neighbourly(saved.map { ($0.dishID, $0.dishName) })
            ForEach(Array(saved.enumerated()), id: \.element.id) { index, dish in
                AteDishRow(
                    photo: .dish(letters[index], cover: dish.dishCoverURL),
                    name: dish.dishName,
                    subtitle: dish.restaurantName,
                    score: dish.dishScore.map(AteScore.average),
                    isFirst: index == 0,
                    isSaved: true,
                    // The row leaves at the tap and comes back if the unsave is refused — the
                    // shelf's own unsave, haptic and event (the one ``SaveAction``).
                    onSave: {
                        Task { await store.unsave(dish) { await app.saves.unsaveFromShelf(dish, source: .search) } }
                    },
                    onOpen: {
                        DishPreviews.shared.note(DishPreview(
                            dishID: dish.dishID, name: dish.dishName,
                            restaurantID: dish.restaurantID, restaurantName: dish.restaurantName,
                            score: dish.dishScore, photoURL: dish.dishCoverURL
                        ))
                        open(.dish(dish.dishID))
                    }
                )
                .accessibilityIdentifier("search.saved")
                .task { await store.loadMoreIfNeeded(index: index) }
            }
        }
    }

    /// Everything the row printed, for the dish page to draw at once (round 6).
    private func openDish(_ dish: DishResult) {
        DishPreviews.shared.note(DishPreview(
            dishID: dish.dishID, name: dish.name,
            restaurantID: dish.restaurantID, restaurantName: dish.restaurantName,
            score: dish.score, photoURL: dish.coverURLString
        ))
        open(.dish(dish.dishID))
    }
}
