import Foundation
import Testing

@testable import AteKit

@Suite("Sitting → reviews batch (§5.1, §6.4)")
struct SittingPostTests {
    private static let reviewer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let restaurantID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func ratedSitting(dishCount: Int) -> SittingState {
        var state = SittingState(
            restaurant: SittingRestaurant(id: Self.restaurantID, name: "Chin Chin", suburb: "Melbourne")
        )
        for index in 0..<dishCount {
            state.add(dishID: UUID(), dishName: "Dish \(index)")
            state.setScore(Rating(rounding: 4), for: state.dishes[index].id)
        }
        return state
    }

    @Test("n cards become n rows in ONE batch, keyed by the client-minted review ids")
    func batch() {
        let state = ratedSitting(dishCount: 3)
        let rows = SittingPost.rows(from: state, reviewerID: Self.reviewer)

        #expect(rows.count == 3)
        #expect(rows.map(\.id) == state.dishes.map(\.id))
        #expect(rows.allSatisfy { $0.reviewerID == Self.reviewer })
        #expect(rows.allSatisfy { $0.restaurantID == Self.restaurantID })
    }

    @Test("restaurant_id is denormalised from the sitting's restaurant, not from the card")
    func denormalisedRestaurant() {
        let rows = SittingPost.rows(from: ratedSitting(dishCount: 1), reviewerID: Self.reviewer)
        #expect(rows.first?.restaurantID == Self.restaurantID)
    }

    @Test("an unrated card produces no row — Rating has no 'unset'")
    func unratedProducesNoRow() {
        var state = ratedSitting(dishCount: 2)
        state.setScore(nil, for: state.dishes[1].id)
        #expect(SittingPost.rows(from: state, reviewerID: Self.reviewer).count == 1)
    }

    @Test("§6.4 a retry writes only the rows that didn't land")
    func retrySkipsPostedRows() {
        let state = ratedSitting(dishCount: 3)
        let alreadyPosted: Set<UUID> = [state.dishes[0].id, state.dishes[2].id]
        let rows = SittingPost.rows(from: state, reviewerID: Self.reviewer, alreadyPosted: alreadyPosted)
        #expect(rows.map(\.id) == [state.dishes[1].id])
    }

    @Test("notes are trimmed to nil, and only an UPLOADED photo reaches the row (§5.1)")
    func notesAndPhotos() {
        var state = ratedSitting(dishCount: 3)
        state.setNote("  ", for: state.dishes[0].id)
        state.setNote("  crunchy  ", for: state.dishes[1].id)
        state.setPhoto(SittingPhoto(localFileName: "a.jpg"), for: state.dishes[0].id)
        state.setPhoto(
            SittingPhoto(localFileName: "b.jpg", uploadState: .uploaded(urlString: "https://x/b.jpg")),
            for: state.dishes[1].id
        )
        state.setPhoto(SittingPhoto(localFileName: "c.jpg", uploadState: .failed), for: state.dishes[2].id)

        let rows = SittingPost.rows(from: state, reviewerID: Self.reviewer)
        #expect(rows[0].note == nil)
        #expect(rows[1].note == "crunchy")
        #expect(rows[0].photoURLString == nil, "an in-flight upload never blocks or half-writes")
        #expect(rows[1].photoURLString == "https://x/b.jpg")
        #expect(rows[2].photoURLString == nil, "a failed upload posts without the photo")
    }

    @Test("a row encodes to exactly the reviews columns the server expects")
    func wireShape() throws {
        let state = ratedSitting(dishCount: 1)
        var mutable = state
        mutable.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)
        let row = try #require(SittingPost.rows(from: mutable, reviewerID: Self.reviewer).first)

        let data = try JSONEncoder().encode(row)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(json.keys) == [
            "id", "reviewer_id", "dish_id", "restaurant_id", "score", "note", "photo_url"
        ])
        #expect(json["score"] as? Double == 4.5)
        #expect(json["note"] is NSNull)
    }

    @Test("the storage path is owner-first, which is what the RLS policy checks")
    func photoPath() {
        let userID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let reviewID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        #expect(ReviewPhotoPath.path(userID: userID, reviewID: reviewID)
            == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg")
        #expect(ReviewPhotoPath.bucket == "review-photos")
    }
}
