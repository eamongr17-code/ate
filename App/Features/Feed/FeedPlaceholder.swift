import AteKit
import Foundation

/// Shaped-but-fake entries for the `.redacted` loading state and for previews.
///
/// The loading state renders *real rows* with real text lengths behind a redaction rather than a
/// spinner, so the list doesn't reflow when the first page lands. That means the placeholder text
/// has to be plausible — a one-word fake would redact to a stub that jumps on load.
enum FeedPlaceholder {
    private static let dishes = ["Cacio e Pepe", "Kouign-Amann", "Son-in-law Eggs", "Prawn Toast"]
    private static let restaurants = ["Tipo 00", "Lune Croissanterie", "Chin Chin", "Supernormal"]
    private static let notes = [
        "Emulsified properly. No clumps, no oil slick. Rare in this town.",
        "Sugar shell, custardy middle. Worth the queue, and I say that rarely."
    ]

    /// The author every placeholder review is by. A real handle length, because the redaction is
    /// drawn at the text's width and a one-character fake would jump when the page lands.
    static let author = User(
        id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        username: "pastaindex",
        name: "Marco Bellini",
        createdAt: .now
    )

    /// Reviews for a dish page's skeleton — plausible note lengths, so the rows are already the
    /// right height (§5).
    static func reviews(count: Int) -> [Review] {
        (0..<count).map { index in
            Review(
                id: UUID(),
                reviewerID: author.id,
                dishID: UUID(),
                restaurantID: UUID(),
                score: Rating(rounding: 4.5),
                note: notes[index % notes.count],
                createdAt: .now,
                updatedAt: .now
            )
        }
    }

    /// Menu rows for a restaurant page's skeleton.
    static func rankedDishes(count: Int) -> [RankedDish] {
        (0..<count).map { index in
            let id = UUID()
            return RankedDish(
                dish: Dish(id: id, name: dishes[index % dishes.count], restaurantID: UUID(), createdAt: .now),
                stats: DishStats(dishID: id, restaurantID: UUID(), score: 4.5, reviewCount: 12)
            )
        }
    }

    static func entries(count: Int) -> [FeedEntry] {
        (0..<count).map { index in
            let id = UUID()
            let dishID = UUID()
            return FeedEntry(
                review: Review(
                    id: id,
                    reviewerID: UUID(),
                    dishID: dishID,
                    restaurantID: UUID(),
                    score: Rating(rounding: 4.5),
                    note: notes[index % notes.count],
                    createdAt: .now,
                    updatedAt: .now
                ),
                dish: FeedEntry.DishSummary(id: dishID, name: dishes[index % dishes.count]),
                restaurant: FeedEntry.RestaurantSummary(
                    id: UUID(),
                    name: restaurants[index % restaurants.count],
                    city: "Melbourne"
                ),
                author: FeedEntry.AuthorSummary(id: UUID(), username: "pastaindex", name: "Marco Bellini")
            )
        }
    }
}
