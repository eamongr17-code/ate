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
