import Foundation

/// What a finished log hands back: the rows that were written, **plus the display strings that were
/// already on screen while they were being written**.
///
/// The rows alone aren't enough to put a block on the diary. A ``Review`` carries UUIDs; a diary row
/// shows a dish name and a restaurant name, and for a dish created seconds ago there is nowhere on
/// the client to look them up. Re-reading the diary would answer it — at the cost of the one moment
/// this exists for, where the sheet slides away and your sitting is *already there*. The sheet knew
/// the names; this is the sheet saying so on the way out.
///
/// Everything else about the row is server truth: ids, timestamps and the uploaded photo URL all
/// come from the inserted ``Review``, so ``DiaryStore/reviewsWerePosted()``'s refresh reconciles onto
/// identical values rather than replacing the block.
public struct PostedSitting: Sendable, Hashable {
    /// The rows the server accepted, in canvas order.
    public let reviews: [Review]
    public let restaurant: SittingRestaurant
    /// `dish_id` → the name stored on the review. §10.6: your record keeps the name you logged, even
    /// if the dish is merged away later.
    public let dishNames: [UUID: String]

    public init(reviews: [Review], restaurant: SittingRestaurant, dishNames: [UUID: String]) {
        self.reviews = reviews
        self.restaurant = restaurant
        self.dishNames = dishNames
    }

    /// The convenience the log flow actually calls: the names come straight off the canvas.
    public init(reviews: [Review], sitting: SittingState) {
        self.init(
            reviews: reviews,
            restaurant: sitting.restaurant,
            dishNames: Dictionary(
                sitting.dishes.map { ($0.dishID, $0.dishName) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    public var isEmpty: Bool { reviews.isEmpty }

    /// The rows as the diary renders them, newest first — the same shape a page from the server has,
    /// so nothing downstream (grouping, paging, dedup) needs to know these arrived by another door.
    ///
    /// A dish whose name is missing is dropped rather than rendered nameless: an unnamed row in your
    /// own record is a bug you'd report, and the refresh behind it will supply the real one.
    public func diaryEntries(author: FeedEntry.AuthorSummary? = nil) -> [FeedEntry] {
        reviews
            .compactMap { review -> FeedEntry? in
                guard let name = dishNames[review.dishID] else { return nil }
                return FeedEntry(
                    review: review,
                    dish: FeedEntry.DishSummary(id: review.dishID, name: name),
                    restaurant: FeedEntry.RestaurantSummary(
                        id: restaurant.id,
                        name: restaurant.name,
                        // `city` is NOT NULL server-side with "" as the no-locality sentinel, so an
                        // absent suburb round-trips to the same "no second line" the refresh brings.
                        city: restaurant.suburb ?? ""
                    ),
                    author: author
                )
            }
            .sorted { lhs, rhs in
                if lhs.review.createdAt != rhs.review.createdAt {
                    return lhs.review.createdAt > rhs.review.createdAt
                }
                // The same total order the keyset uses, so an optimistic row sits exactly where the
                // refreshed page will put it.
                return lhs.id.uuidString.lowercased() > rhs.id.uuidString.lowercased()
            }
    }
}
