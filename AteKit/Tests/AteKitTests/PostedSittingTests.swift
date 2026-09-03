import Foundation
import Testing

@testable import AteKit

/// §7.4 — the just-posted sitting lands on the diary before the sheet has finished leaving.
///
/// The behaviour under test is not "a list gained rows"; it is that the *first* thing someone ever
/// logs is on their record instantly rather than behind a loading skeleton, and that the refresh
/// running behind it reconciles instead of duplicating.
@Suite("Posted sitting → diary")
@MainActor
struct PostedSittingTests {

    private static let restaurant = SittingRestaurant(id: UUID(), name: "Tipo 00", suburb: "Carlton")
    private static let epoch = Date(timeIntervalSince1970: 1_788_000_000)

    private static func posted(
        dishes: [(name: String, score: Double)],
        photoURL: String? = nil
    ) -> PostedSitting {
        var sitting = SittingState(restaurant: restaurant)
        var reviews: [Review] = []
        for (index, dish) in dishes.enumerated() {
            let dishID = UUID()
            sitting.add(dishID: dishID, dishName: dish.name)
            reviews.append(Review(
                id: UUID(),
                reviewerID: UUID(),
                dishID: dishID,
                restaurantID: restaurant.id,
                score: Rating(exactly: dish.score)!,
                photoURLString: index == 0 ? photoURL : nil,
                createdAt: epoch.addingTimeInterval(Double(index)),
                updatedAt: epoch.addingTimeInterval(Double(index))
            ))
        }
        return PostedSitting(reviews: reviews, sitting: sitting)
    }

    // MARK: - Building the rows

    @Test("The rows carry the names the canvas posted them under")
    func carriesDisplayNames() {
        let entries = Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]).diaryEntries()

        // Newest first, the order the diary reads in.
        #expect(entries.map(\.dish.name) == ["Tiramisu", "Bucatini"])
        #expect(entries.allSatisfy { $0.restaurant.name == "Tipo 00" })
        #expect(entries[0].restaurant.locality == "Carlton")
        #expect(entries[0].review.score.value == 3.0)
    }

    @Test("A restaurant with no suburb renders no second line, exactly as the refresh will")
    func missingSuburbMatchesServerSentinel() {
        let sitting = SittingState(restaurant: SittingRestaurant(id: UUID(), name: "Nonna's"))
        let review = Review(
            id: UUID(),
            reviewerID: UUID(),
            dishID: UUID(),
            restaurantID: UUID(),
            score: Rating(exactly: 5.0)!,
            createdAt: Self.epoch,
            updatedAt: Self.epoch
        )
        let posted = PostedSitting(
            reviews: [review],
            restaurant: sitting.restaurant,
            dishNames: [review.dishID: "Lasagne"]
        )

        #expect(posted.diaryEntries()[0].restaurant.city.isEmpty)
        #expect(posted.diaryEntries()[0].restaurant.locality == nil)
    }

    @Test("§10.7 a review whose photo upload failed is a photoless row, not a missing one")
    func photolessRowSurvives() {
        let entries = Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]).diaryEntries()

        #expect(entries.count == 2)
        #expect(entries.contains { $0.review.photoURL == nil })
    }

    @Test("A row with no name to show is dropped rather than rendered nameless")
    func unnamedRowIsDropped() {
        let review = Review(
            id: UUID(),
            reviewerID: UUID(),
            dishID: UUID(),
            restaurantID: UUID(),
            score: Rating(exactly: 4.0)!,
            createdAt: Self.epoch,
            updatedAt: Self.epoch
        )
        let posted = PostedSitting(reviews: [review], restaurant: Self.restaurant, dishNames: [:])

        #expect(posted.diaryEntries().isEmpty)
    }

    // MARK: - The store

    @Test("The posted sitting is on the page immediately, as one block")
    func insertPostedShowsBlockAtOnce() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()
        #expect(store.phase == .empty)

        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]))

        #expect(store.phase == .ready)
        #expect(store.entries.count == 2)
        #expect(store.months.count == 1)
        // Both dishes, one visit — the thing that makes the diary a record rather than a list.
        #expect(store.months[0].sittings.count == 1)
        #expect(store.months[0].sittings[0].dishCount == 2)
        #expect(store.months[0].dishCount == 2)
    }

    @Test("Re-reporting rows that are already on the page doesn't double them")
    func insertPostedIsIdempotent() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()
        let posted = Self.posted(dishes: [("Bucatini", 4.5)])

        store.insertPosted(posted)
        store.insertPosted(posted)

        #expect(store.entries.count == 1)
    }

    @Test("Rows posted by a session we no longer have are not ours to show")
    func signedOutStoreIgnoresInsert() async {
        let store = DiaryStore(client: SignedOutDiary())
        await store.loadIfNeeded()
        #expect(store.phase == .signedOut)

        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5)]))

        #expect(store.entries.isEmpty)
        #expect(store.phase == .signedOut)
    }

    @Test("An empty post changes nothing")
    func emptyPostIsANoOp() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()

        store.insertPosted(PostedSitting(reviews: [], restaurant: Self.restaurant, dishNames: [:]))

        #expect(store.phase == .empty)
        #expect(store.entries.isEmpty)
    }

    @Test("The record line counts the sitting you just posted")
    func recordLineIncludesTheNewSitting() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()

        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]))

        #expect(store.recordLine == "2 dishes · 1 place")
    }

    // MARK: - The composer rule (§3.1)

    @Test("The composer is present in every phase except signed out — loading and failed included")
    func composerSurvivesEveryPhaseButSignedOut() {
        #expect(DiaryStore.Phase.loading.allowsComposer)
        #expect(DiaryStore.Phase.ready.allowsComposer)
        #expect(DiaryStore.Phase.empty.allowsComposer)
        #expect(DiaryStore.Phase.failed(message: "You're offline.").allowsComposer)
        #expect(!DiaryStore.Phase.signedOut.allowsComposer)
    }

    // MARK: - The entry view's seams (§4)

    @Test("An entry on the page resolves by review id, with no network")
    func entryLookup() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()
        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]))
        let target = store.entries[0]

        #expect(store.entry(withReviewID: target.review.id)?.dish.name == target.dish.name)
        #expect(store.entry(withReviewID: UUID()) == nil)
    }

    @Test("Siblings are the rest of the same sitting — the block the diary actually draws")
    func sittingSiblings() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()
        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5), ("Tiramisu", 3.0)]))
        let target = store.entries[0]

        let siblings = store.sittingSiblings(ofReviewID: target.review.id)
        #expect(siblings.count == 1)
        // The entry is never its own sibling.
        #expect(!siblings.contains { $0.review.id == target.review.id })
        // …and the pair agrees with the block on the list, which is the point of sharing the rule.
        #expect(store.months[0].sittings[0].dishCount == siblings.count + 1)
    }

    @Test("A single-dish sitting has no siblings, and neither does an id we've never loaded")
    func noSiblings() async {
        let store = DiaryStore(client: EmptyDiary())
        await store.loadIfNeeded()
        store.insertPosted(Self.posted(dishes: [("Bucatini", 4.5)]))

        #expect(store.sittingSiblings(ofReviewID: store.entries[0].review.id).isEmpty)
        #expect(store.sittingSiblings(ofReviewID: UUID()).isEmpty)
    }

    @Test("Each of the diary's three log doors reports itself distinctly (§9)")
    func logCTAOriginsAreDistinct() async {
        let recorder = CapturedEvents()
        let store = DiaryStore(client: EmptyDiary(), analytics: recorder.record)

        store.recordLogCTATapped(from: .diaryComposer)
        store.recordLogCTATapped(from: .diaryResume)
        store.recordLogCTATapped(from: .diaryEmpty)

        #expect(recorder.events.map(\.name) == ["log_cta_tapped", "log_cta_tapped", "log_cta_tapped"])
        #expect(recorder.events.compactMap { $0.parameters["from"] }
            == ["diary_composer", "diary_resume", "diary_empty"])
    }
}

private final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AnalyticsEvent] = []

    var record: AnalyticsRecorder {
        { [self] event in lock.withLock { storage.append(event) } }
    }

    var events: [AnalyticsEvent] { lock.withLock { storage } }
}

/// A backend with nothing in it — the first-run diary.
private struct EmptyDiary: DiaryReading {
    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        Page(items: [], nextCursor: nil)
    }
}

private struct SignedOutDiary: DiaryReading {
    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        throw AteAPIError.notAuthenticated
    }
}
