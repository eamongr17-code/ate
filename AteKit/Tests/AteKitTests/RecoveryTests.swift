import Foundation
import Testing

@testable import AteKit

/// Dismissing a photo suggestion for good, and the recovery funnel's events.
@MainActor
@Suite("Suggestions — dismissed for good")
struct PhotoSuggestionDismissalsTests {

    private let now = Date(timeIntervalSince1970: 1_789_776_000)
    private let owner = UUID()

    private func item(_ id: String, hoursAgo: Double) -> PhotoSuggestionItem {
        PhotoSuggestionItem(id: id, createdAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    private var items: [PhotoSuggestionItem] {
        [item("a", hoursAgo: 2), item("b", hoursAgo: 2.2), item("c", hoursAgo: 30)]
    }

    @Test("An X takes the row's photos off, and the badge counts only what is left")
    func dismissRemovesTheRow() {
        let store = InMemoryKeyValueStore()
        let dismissals = PhotoSuggestionDismissals(store: store, owner: owner, now: { self.now })
        let clusters = dismissals.clusters(items)
        #expect(clusters.count == 2)
        #expect(dismissals.count(items) == 3)

        dismissals.dismiss(clusters[0])
        #expect(dismissals.clusters(items).map(\.id) == ["c"])
        #expect(dismissals.count(items) == 1)
    }

    @Test("Gone for the next launch too — but only for the person who dismissed it")
    func remembersPerPerson() {
        let store = InMemoryKeyValueStore()
        let first = PhotoSuggestionDismissals(store: store, owner: owner, now: { self.now })
        first.dismiss(first.clusters(items)[0])

        let relaunched = PhotoSuggestionDismissals(store: store, owner: owner, now: { self.now })
        #expect(relaunched.contains("a"))
        #expect(relaunched.count(items) == 1)

        let somebodyElse = PhotoSuggestionDismissals(store: store, owner: UUID(), now: { self.now })
        #expect(somebodyElse.count(items) == 3)
    }

    @Test("A photo taken after the dismissal is offered on its own")
    func newPhotosStillCome() {
        let store = InMemoryKeyValueStore()
        let dismissals = PhotoSuggestionDismissals(store: store, owner: owner, now: { self.now })
        dismissals.dismiss(dismissals.clusters(items)[0])
        let later = items + [item("d", hoursAgo: 1)]
        #expect(dismissals.clusters(later).map(\.id) == ["d", "c"])
    }

    @Test("Photos that have aged out of the window are forgotten rather than kept forever")
    func prunesTheOld() {
        let store = InMemoryKeyValueStore()
        var clock = now
        let dismissals = PhotoSuggestionDismissals(store: store, owner: owner, now: { clock })
        dismissals.dismiss(PhotoSuggestionCluster(items: [item("old", hoursAgo: 1)]))
        clock = now.addingTimeInterval(PhotoSuggestions.window + 7200)
        dismissals.dismiss(PhotoSuggestionCluster(items: [
            PhotoSuggestionItem(id: "new", createdAt: clock.addingTimeInterval(-60))
        ]))
        let reread = PhotoSuggestionDismissals(store: store, owner: owner, now: { clock })
        #expect(reread.contains("new"))
        #expect(reread.contains("old") == false)
    }
}

@Suite("Recovery events")
struct RecoveryEventsTests {

    @Test("Every failure has its own words and its own event")
    func failures() {
        let titles = Set(ActionFailure.allCases.map(\.title))
        #expect(titles.count == ActionFailure.allCases.count)
        #expect(ActionFailure.allCases.allSatisfy { $0.title.hasPrefix("Couldn't ") })
        let event = RecoveryEvents.actionFailed(.correctDish)
        #expect(event.name == "action_failed")
        #expect(event.parameters == ["action": "correct_dish"])
    }

    @Test("The names are what the dashboard groups on")
    func names() {
        #expect(RecoveryEvents.detailUnreachable(.place).name == "detail_unreachable")
        #expect(RecoveryEvents.detailUnreachable(.dish).parameters == ["surface": "dish"])
        #expect(RecoveryEvents.detailRetried(.place).name == "detail_retried")
        #expect(RecoveryEvents.unsaveUndone().name == "unsave_undone")
        #expect(SuggestionEvents.dismissed(photos: 3).parameters == ["photos": "3"])
        #expect(SuggestionEvents.photoAccessSettingsOpened().name == "photo_access_settings_opened")
    }
}

@Suite("Ate's one domain")
struct AteLegalTests {
    @Test("Every link hangs off the one site constant")
    func oneHost() {
        let site = AteLegal.site.absoluteString
        #expect(AteLegal.privacy.absoluteString == site + "/privacy")
        #expect(AteLegal.terms.host() == AteLegal.site.host())
        let jess = AteLegal.profile(handle: "jessw")?.absoluteString
        #expect(jess == site + "/@jessw")
        #expect(AteLegal.profile(handle: "not a handle") == nil)
        #expect(AteLegal.arePlaceholders, "flip this test the day the real domain lands")
    }
}

@MainActor
@Suite("Place and dish pages drop a deleted entry")
struct DetailDeletionTests {
    private let placeID = UUID()
    private let dishID = UUID()
    private let author = EntryCard.Author(id: UUID(), username: "jessw")

    private func card(_ id: UUID) -> EntryCard {
        EntryCard(
            id: id, authorID: author.id, body: "Good.", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000), isMine: false, author: author,
            place: EntryCard.Place(id: placeID, name: "Tipo 00")
        )
    }

    private func review(_ entry: UUID) -> DishReview {
        DishReview(
            reviewID: UUID(), entryID: entry, author: author, score: nil, note: nil,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000), isMine: false
        )
    }

    @Test("A deleted visit leaves the place page's list, and its review leaves the dish page")
    func deletedEntryVanishes() async {
        let source = FakePlaceDishSource()
        let gone = UUID()
        source.seed(place: PlaceSummary(restaurantID: placeID, name: "Tipo 00"), entries: [card(gone), card(UUID())])
        source.seed(
            dish: DishSummary(dishID: dishID, name: "Ragù", restaurantID: placeID, restaurantName: "Tipo 00"),
            reviews: [review(gone), review(UUID())]
        )
        let deletions = EntryDeletions()
        let place = PlacePageStore(restaurantID: placeID, places: source, deletions: deletions)
        let dish = DishPageStore(dishID: dishID, dishes: source, deletions: deletions)
        await place.load()
        await dish.load()
        #expect(place.entries.entries.count == 2)
        #expect(dish.reviews.count == 2)

        deletions.send(gone)
        #expect(place.entries.entries.map(\.id).contains(gone) == false)
        #expect(dish.reviews.contains { $0.entryID == gone } == false)
        #expect(dish.reviews.count == 1)
    }
}
