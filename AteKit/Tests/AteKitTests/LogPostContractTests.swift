import Foundation
import Supabase
import Testing

@testable import AteKit

/// The log flow's **write** contract, against real staging rows.
///
/// Everything else about a sitting is pure and unit-tested; this is the one part that can only be
/// wrong on the wire: whether Postgres accepts an n-row insert with client-supplied ids, whether the
/// denormalised `restaurant_id` survives the trigger, whether the score CHECK matches ``Rating``, and
/// whether re-sending a batch after a timeout is genuinely idempotent (§6.4).
///
/// Opt-in like the rest of the staging suite (`ATE_CONTRACT_TESTS=1`). **It cleans up after itself**
/// — a contract test that leaves rows behind turns staging into a landfill one CI run at a time.
@Suite("Log post contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct LogPostContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// A restaurant in the seed with at least two dishes — the multi-dish sitting this suite needs.
    private func sittingFixture(client: AteAPIClient) async throws -> (SittingRestaurant, [Dish]) {
        let dishes = try await client.page(Dish.self, request: PageRequest(limit: 100)).items
        let byRestaurant = Dictionary(grouping: dishes.filter { !$0.isTombstoned }, by: \.restaurantID)
        let pair = try #require(byRestaurant.first { $0.value.count >= 2 })
        let restaurant = try await client.fetchByID(Restaurant.self, id: pair.key)
        return (
            SittingRestaurant(id: restaurant.id, name: restaurant.name, suburb: restaurant.locality),
            Array(pair.value.prefix(2))
        )
    }

    /// Set `ATE_KEEP_CONTRACT_ROWS=1` to leave the posted sitting in staging — how a human looks at
    /// what the flow actually writes (it shows up at the top of the staging feed). Off by default,
    /// so CI doesn't accumulate rows.
    private var keepsRows: Bool { StagingContract.environmentValue("ATE_KEEP_CONTRACT_ROWS") != nil }

    private func delete(_ ids: [UUID], client: AteAPIClient) async throws {
        guard !ids.isEmpty else { return }
        guard !keepsRows else {
            print("Kept staging reviews: \(ids.map(\.uuidString).joined(separator: ", "))")
            return
        }
        _ = try await client.supabase
            .from(Review.table)
            .delete()
            .in("id", values: ids.map(\.uuidString))
            .execute()
    }

    @Test("a two-dish sitting posts as ONE batch, with the client's ids and the denormalised restaurant")
    func postsABatch() async throws {
        let client = try await client()
        let reviewerID = try await client.requireCurrentUserID()
        let (restaurant, dishes) = try await sittingFixture(client: client)

        var sitting = SittingState(restaurant: restaurant)
        sitting.add(dishID: dishes[0].id, dishName: dishes[0].name)
        sitting.add(dishID: dishes[1].id, dishName: dishes[1].name)
        sitting.setScore(Rating(rounding: 4.5), for: sitting.dishes[0].id)
        sitting.setNote("  contract test — batched insert  ", for: sitting.dishes[0].id)
        sitting.setScore(Rating(rounding: 0.5), for: sitting.dishes[1].id)

        let rows = SittingPost.rows(from: sitting, reviewerID: reviewerID)
        let poster = ReviewPostingService(api: client)
        let inserted = try await poster.post(rows)

        do {
            #expect(inserted.count == 2)
            #expect(Set(inserted.map(\.id)) == Set(rows.map(\.id)), "the client's ids are the row ids")
            #expect(inserted.allSatisfy { $0.reviewerID == reviewerID })
            #expect(inserted.allSatisfy { $0.restaurantID == restaurant.id },
                    "restaurant_id is denormalised from the dish, and we sent it correctly")

            let first = try #require(inserted.first { $0.id == rows[0].id })
            #expect(first.score.value == 4.5)
            #expect(first.note == "contract test — batched insert", "the note is trimmed, not padded")
            #expect(first.photoURLString == nil)

            let floor = try #require(inserted.first { $0.id == rows[1].id })
            #expect(floor.score == Rating.minimum, "0.5 is postable; 0 does not exist")

            // §6.4: re-sending the same batch (a retry after a timeout that actually committed)
            // returns the same rows instead of writing a second copy.
            let retried = try await poster.post(rows)
            #expect(Set(retried.map(\.id)) == Set(rows.map(\.id)))

            let mine = try await client.page(Review.self, request: PageRequest(limit: 100)) {
                $0.eq("reviewer_id", value: reviewerID.uuidString)
                    .eq("dish_id", value: dishes[0].id.uuidString)
            }.items
            #expect(mine.filter { $0.id == rows[0].id }.count == 1, "a retry must not duplicate a review")
        }

        try await delete(rows.map(\.id), client: client)
    }

    @Test("an empty batch is a no-op, not a round trip")
    func emptyBatch() async throws {
        let inserted = try await ReviewPostingService(api: try await client()).post([])
        #expect(inserted.isEmpty)
    }

    @Test("a review photo uploads to the viewer's own folder and reads back publicly")
    func uploadsAPhoto() async throws {
        let client = try await client()
        let userID = try await client.requireCurrentUserID()
        let reviewID = UUID()

        // A 1×1 JPEG. The bucket stores bytes; what matters here is the path policy and the URL.
        let jpeg = Data(base64Encoded: """
            /9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a\
            HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA\
            AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==
            """.replacingOccurrences(of: "\n", with: ""))
        let bytes = try #require(jpeg)

        let url = try await ReviewPhotoUploadService(api: client).upload(bytes, reviewID: reviewID)
        let expectedPath = ReviewPhotoPath.path(userID: userID, reviewID: reviewID)
        #expect(url.absoluteString.contains(expectedPath), "owner-first path — the RLS policy's check")

        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "the bucket is public-read")
        #expect(data.isEmpty == false)

        _ = try? await client.supabase.storage
            .from(ReviewPhotoPath.bucket)
            .remove(paths: [expectedPath])
    }
}
