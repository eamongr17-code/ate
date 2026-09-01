import Foundation
import PostgREST
import Supabase

/// One row of the batched `reviews` insert (§5.1).
///
/// The id travels **from the client**. Postgres would happily mint one, but then a retry after a
/// timeout that actually succeeded would write a duplicate review; with a client id the retry is a
/// no-op on the rows that landed and an insert on the rows that didn't (§6.4).
public struct NewReview: Encodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let reviewerID: UUID
    public let dishID: UUID
    /// Denormalised from the dish (`dishes.restaurant_id`). The server trigger keeps it honest; we
    /// send it so the row is complete on arrival.
    public let restaurantID: UUID
    public let score: Rating
    public let note: String?
    public let photoURLString: String?

    public init(
        id: UUID,
        reviewerID: UUID,
        dishID: UUID,
        restaurantID: UUID,
        score: Rating,
        note: String? = nil,
        photoURLString: String? = nil
    ) {
        self.id = id
        self.reviewerID = reviewerID
        self.dishID = dishID
        self.restaurantID = restaurantID
        self.score = score
        self.note = note
        self.photoURLString = photoURLString
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reviewerID = "reviewer_id"
        case dishID = "dish_id"
        case restaurantID = "restaurant_id"
        case score
        case note
        case photoURLString = "photo_url"
    }

    /// Written by hand, and every key is always present — including the nulls.
    ///
    /// The synthesised encoder omits nil optionals, and PostgREST's **bulk** insert derives its
    /// column list from the rows it is given: a batch where one dish has a note and another doesn't
    /// would arrive with mismatched keys. Explicit nulls make an n-row batch one uniform statement.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(reviewerID, forKey: .reviewerID)
        try container.encode(dishID, forKey: .dishID)
        try container.encode(restaurantID, forKey: .restaurantID)
        try container.encode(score, forKey: .score)
        try container.encode(note, forKey: .note)
        try container.encode(photoURLString, forKey: .photoURLString)
    }
}

/// Turns a sitting into the rows it posts. Pure, and the only place the mapping exists.
public enum SittingPost {
    /// The batch. `alreadyPosted` is the retry path (§6.4): rows that already landed are skipped, so
    /// a second attempt writes only what's missing.
    ///
    /// An unrated card cannot produce a row — `Rating` has no representation for "unset", which is
    /// exactly why the score is optional on the card and non-optional here.
    public static func rows(
        from state: SittingState,
        reviewerID: UUID,
        alreadyPosted: Set<UUID> = []
    ) -> [NewReview] {
        state.dishes.compactMap { dish in
            guard let score = dish.score, !alreadyPosted.contains(dish.id) else { return nil }
            return NewReview(
                id: dish.id,
                reviewerID: reviewerID,
                dishID: dish.dishID,
                restaurantID: state.restaurant.id,
                score: score,
                note: dish.trimmedNote,
                // §5.1: a photo that hasn't finished (or has failed) does not hold up the post.
                photoURLString: dish.photo?.uploadState.uploadedURLString
            )
        }
    }
}

/// The write half of the log flow. One method, because the flow makes exactly one write.
public protocol ReviewPosting: Sendable {
    /// Inserts every row in ONE round trip and returns the rows as the server stored them.
    func post(_ rows: [NewReview]) async throws -> [Review]
}

/// Live implementation.
///
/// Uses the raw PostgREST builder rather than ``AteAPIClient/insert(_:into:)`` for one reason: that
/// helper is `.single()`, and a sitting is n rows in **one** statement (§5.1 — "writes n reviews rows
/// in ONE batched insert (single round-trip)"). Looping the single-row helper would turn a two-dish
/// sitting into two writes with two ways to half-fail.
public struct ReviewPostingService: ReviewPosting {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func post(_ rows: [NewReview]) async throws -> [Review] {
        guard !rows.isEmpty else { return [] }
        _ = try await api.requireCurrentUserID()
        do {
            return try await api.supabase
                .from(Review.table)
                .insert(rows, returning: .representation)
                .select(Review.columns)
                .execute()
                .value
        } catch {
            // §6.4: a retry after a request that timed out *after* the server committed comes back
            // as a primary-key violation on our own client ids. That is a success we didn't hear
            // about, not a failure — read the rows back instead of showing an error for a review
            // that exists.
            guard (error as? PostgrestError)?.code == "23505" else { throw error }
            return try await api.fetchByIDs(Review.self, ids: rows.map(\.id))
        }
    }
}
