import Foundation
import Testing
@testable import AteKit

/// Collects events, across actors.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AnalyticsEvent] = []
    var events: [AnalyticsEvent] { lock.withLock { all } }
    var recorder: AnalyticsRecorder { { [self] event in lock.withLock { all.append(event) } } }
}

private enum Fixture {
    static let viewer = EntryCard.Author(id: UUID(), username: "jess")
    static let tagger = AteNotification.Person(id: UUID(), username: "eamon")
    static let place = AteWithPrefill.Place(id: UUID(), name: "Tipo 00", address: "361 Little Bourke St")
    static let ragu = AteWithPrefill.Dish(dishID: UUID(), dishName: "Tagliatelle al ragù", position: 1)
    static let tiramisu = AteWithPrefill.Dish(dishID: UUID(), dishName: "Tiramisu", position: 2)
    static let prawns = AteWithPrefill.Dish(dishID: UUID(), dishName: "Prawn spaghetti", position: 3)

    /// A tag `minutesAgo` old, at Tipo 00 with three dishes.
    static func tag(
        minutesAgo: Double, createdAt: Date? = nil, id: UUID = UUID(), read: Bool = false,
        sortStatus: EntrySortStatus = .sorted, dishes: [AteWithPrefill.Dish] = [ragu, tiramisu, prawns]
    ) -> InMemoryNotifications.Tag {
        let companionID = UUID()
        let entryID = UUID()
        let visited = Date(timeIntervalSince1970: 1_789_810_200)
        let created = createdAt ?? Date(timeIntervalSince1970: 1_790_000_000 - minutesAgo * 60)
        return InMemoryNotifications.Tag(
            notification: AteNotification(
                id: id, createdAt: created, readAt: read ? created : nil, actor: tagger, companionID: companionID,
                entryID: entryID, place: AteNotification.Place(id: place.id, name: place.name), visitedAt: visited
            ),
            prefill: AteWithPrefill(
                companionID: companionID, entryID: entryID, visitedAt: visited, sortStatus: sortStatus,
                tagger: tagger, place: place, dishes: dishes
            )
        )
    }
}

@Suite("Ate with: decoding")
struct AteWithDecodingTests {

    @Test func notificationRowDecodes() throws {
        let json = Data("""
        [{"id":"6f1c4b2a-0000-4000-8000-000000000001","type":"ate_with",
          "created_at":"2026-09-19T12:30:25.240956+00:00","read_at":null,
          "actor":{"id":"6f1c4b2a-0000-4000-8000-0000000000aa","username":"eamon","name":"Eamon","avatar_url":null},
          "companion_id":"6f1c4b2a-0000-4000-8000-0000000000c1","companion_status":"pending",
          "entry_id":"6f1c4b2a-0000-4000-8000-0000000000e1",
          "place":{"id":"6f1c4b2a-0000-4000-8000-0000000000b1","name":"Tipo 00","locality":"Melbourne"},
          "visited_at":"2026-09-19T09:30:00+00:00"}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([AteNotification].self, from: json)
        let row = try #require(rows.first)
        #expect(row.actor.username == "eamon")
        #expect(row.place?.name == "Tipo 00")
        #expect(row.companionStatus == .pending)
        #expect(row.isUnread)
        #expect(row.isRenderable)
        #expect(row.cursor.id == row.id)
        // Microseconds survive: the keyset cursor must match the row exactly.
        #expect(PostgRESTTimestamp.string(from: row.createdAt).contains("25.240956"))
    }

    @Test func anotherTypeOrNoPlaceStillDecodesButOnlyAteWithRenders() throws {
        let json = Data("""
        [{"id":"6f1c4b2a-0000-4000-8000-000000000002","type":"follow","created_at":"2026-09-19T12:30:25Z",
          "read_at":"2026-09-19T12:31:00Z","actor":{"id":"6f1c4b2a-0000-4000-8000-0000000000aa","username":"eamon"},
          "companion_id":null,"companion_status":"mystery","entry_id":null,"place":null,"visited_at":null}]
        """.utf8)
        let row = try #require(try PostgRESTDate.decoder.decode([AteNotification].self, from: json).first)
        #expect(row.isRenderable == false)
        #expect(row.companionStatus == nil)
        #expect(row.isUnread == false)
    }

    @Test func prefillDecodes() throws {
        let json = Data("""
        {"companion_id":"6f1c4b2a-0000-4000-8000-0000000000c1","status":"pending","response_entry_id":null,
         "entry_id":"6f1c4b2a-0000-4000-8000-0000000000e1","visited_at":"2026-09-19T09:30:00.5+00:00",
         "sort_status":"sorted",
         "tagger":{"id":"6f1c4b2a-0000-4000-8000-0000000000aa","username":"eamon","name":null,"avatar_url":null},
         "place":{"id":"6f1c4b2a-0000-4000-8000-0000000000b1","name":"Tipo 00","address":"361 Little Bourke St",
                  "locality":"Melbourne"},
         "dishes":[{"dish_id":"6f1c4b2a-0000-4000-8000-0000000000d2","dish_name":"Tiramisu","position":2},
                   {"dish_id":"6f1c4b2a-0000-4000-8000-0000000000d1","dish_name":"Tagliatelle al ragù","position":1}]}
        """.utf8)
        let prefill = try PostgRESTDate.decoder.decode(AteWithPrefill.self, from: json)
        #expect(prefill.status == .pending)
        #expect(prefill.place?.address == "361 Little Bourke St")
        #expect(prefill.dishes.count == 2)
        #expect(prefill.isStillSorting == false)
    }

    @Test func itemsEncodeScoreOnlyWhenScored() throws {
        let dish = UUID()
        let scored = try JSONEncoder().encode(AteWithItem(dishID: dish, score: Rating(exactly: 4.5)))
        let unscored = try JSONEncoder().encode(AteWithItem(dishID: dish, score: nil))
        let scoredObject = try #require(try JSONSerialization.jsonObject(with: scored) as? [String: Any])
        let unscoredObject = try #require(try JSONSerialization.jsonObject(with: unscored) as? [String: Any])
        #expect(scoredObject["score"] as? Double == 4.5)
        #expect(unscoredObject["score"] == nil)
        #expect(unscoredObject["dish_id"] as? String == dish.uuidString)
    }

    @Test func errorsMapFromTheContractCodes() {
        #expect(AteWithError(code: "P0002", message: "tag_not_found") == .gone)
        #expect(AteWithError(code: "23505", message: "already_responded") == .alreadyAnswered)
        #expect(AteWithError(code: "22023", message: "tag_declined") == .declined)
        #expect(AteWithError(code: "22023", message: "dish_not_at_place") == .unreachable)
        #expect(AteWithError(code: nil, message: nil) == .unreachable)
    }

    @Test func apnsEnvironmentFollowsTheBuildConfiguration() {
        #expect(APNsEnvironment.forBuild(isDebugBuild: true) == .sandbox)
        #expect(APNsEnvironment.forBuild(isDebugBuild: false) == .production)
        #expect(APNsEnvironment.hex(Data([0x0A, 0xFF, 0x00])) == "0aff00")
    }
}

@MainActor
@Suite("Ate with: the notifications store")
struct NotificationsStoreTests {

    @Test func pagesNewestFirstOnTheTwoPartKeyset() async {
        // Three rows share one timestamp: only the id tiebreak pages them without a loop or a skip.
        let same = Date(timeIntervalSince1970: 1_790_000_000)
        let tags = (0..<5).map { Fixture.tag(minutesAgo: Double($0), createdAt: $0 < 3 ? same : nil) }
        let service = InMemoryNotifications(tags: tags)
        let store = NotificationsStore(reads: service, pageSize: 2)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.rows.count == 2)
        await store.loadMore()
        await store.loadMore()
        await store.loadMore()
        #expect(store.rows.count == 5)
        #expect(Set(store.rows.map(\.id)).count == 5)
        let keys = store.rows.map { ($0.createdAt, $0.id.uuidString) }
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func emptyAndFailedAreTheirOwnStates() async {
        let empty = NotificationsStore(reads: InMemoryNotifications())
        await empty.loadIfNeeded()
        #expect(empty.isEmpty)

        let failing = InMemoryNotifications(tags: [Fixture.tag(minutesAgo: 1)])
        failing.failsReads = true
        let failed = NotificationsStore(reads: failing)
        await failed.loadIfNeeded()
        #expect(failed.phase == .failed)
        failing.failsReads = false
        await failed.refresh()
        #expect(failed.phase == .ready)
        #expect(failed.rows.count == 1)
    }

    @Test func unreadCountCountsWhatIsWaitingAndUnread() async {
        let service = InMemoryNotifications(tags: [
            Fixture.tag(minutesAgo: 1), Fixture.tag(minutesAgo: 2), Fixture.tag(minutesAgo: 3, read: true)
        ])
        let store = NotificationsStore(reads: service)
        await store.refreshCount()
        #expect(store.unreadCount == 2)
    }

    @Test func theXClearsTheRowButKeepsTheTag() async throws {
        let tag = Fixture.tag(minutesAgo: 1)
        let service = InMemoryNotifications(tags: [tag, Fixture.tag(minutesAgo: 2)])
        let recorded = Recorded()
        let store = NotificationsStore(reads: service, analytics: recorded.recorder)
        await store.refresh()
        #expect(store.unreadCount == 2)
        let row = try #require(store.rows.first)
        await store.dismiss(row)
        #expect(store.rows.contains { $0.id == row.id } == false)
        #expect(store.unreadCount == 1)
        #expect(recorded.events.map(\.name) == ["notification_dismissed"])
        #expect(recorded.events.first?.parameters["how"] == "x")
        // The server agrees after a reload, and the tag itself can still be answered.
        await store.refresh()
        #expect(store.rows.count == 1)
        let companionID = try #require(tag.notification.companionID)
        #expect(service.tag(companionID: companionID)?.status == .pending)
        _ = try await service.prefill(companionID: companionID)
    }
}

@MainActor
@Suite("Ate with: answering a tag")
struct AteWithRespondTests {

    @Test func prefillThenPostCreatesTheirOwnEntryAndTheRowGoes() async throws {
        let tag = Fixture.tag(minutesAgo: 1)
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag], viewer: Fixture.viewer, firstOrderNumber: 39)
        let recorded = Recorded()
        let store = NotificationsStore(reads: service)
        await store.refresh()
        #expect(store.rows.count == 1)

        let model = AteWithRespondModel(companionID: companionID, service: service, analytics: recorded.recorder)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.prefill?.place?.name == "Tipo 00")
        #expect(model.lines.map(\.name) == ["Tagliatelle al ragù", "Tiramisu", "Prawn spaghetti"])
        #expect(model.current == Fixture.ragu.dishID)

        // Three drags would be three dishes; she had two: score, skip one, score.
        model.finish(at: try #require(Rating(exactly: 4)))
        #expect(model.current == Fixture.tiramisu.dishID, "letting go moves to the next row")
        model.remove(Fixture.tiramisu.dishID)
        #expect(model.current == Fixture.prawns.dishID)
        model.finish(at: try #require(Rating(exactly: 4.5)))
        #expect(model.current == nil, "every row done: the slide folds away")
        #expect(model.canPost)

        let card = try await model.post()
        #expect(card.authorID == Fixture.viewer.id, "THEIR entry, not the tagger's")
        #expect(card.restaurantID == Fixture.place.id, "the same place")
        #expect(card.createdAt == tag.prefill.visitedAt, "dated the visit")
        #expect(card.items.map(\.dishName) == ["Tagliatelle al ragù", "Prawn spaghetti"])
        #expect(card.items.map { $0.score?.value } == [4, 4.5])
        #expect(card.sortStatus == .sorted)
        #expect(card.orderNumber == 39)
        #expect(recorded.events.last?.name == "ate_with_posted")
        #expect(recorded.events.last?.parameters
            == ["scored": "2", "removed": "1", "unscored": "0", "has_words": "false"])

        // A retry with the same minted id is the same card, not a second entry.
        let again = try await service.respond(companionID: companionID, entryID: model.entryID, items: [], body: "")
        #expect(again.id == card.id)
        #expect(service.posted.count == 1)

        store.finished(companionID: companionID)
        #expect(store.rows.isEmpty)
        #expect(store.unreadCount == 0)
        await store.refresh()
        #expect(store.rows.isEmpty, "answering dismissed the row on the server too")
    }

    @Test func aDeletedOriginalIsGoneOnOpen() async throws {
        let tag = Fixture.tag(minutesAgo: 1)
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag])
        service.withdraw(companionID: companionID)
        let model = AteWithRespondModel(companionID: companionID, service: service)
        await model.load()
        #expect(model.phase == .gone)
        #expect(model.canPost == false)
    }

    @Test func anOriginalDeletedWhileOpenTurnsThePostGone() async throws {
        let tag = Fixture.tag(minutesAgo: 1)
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag])
        let model = AteWithRespondModel(companionID: companionID, service: service)
        await model.load()
        service.withdraw(companionID: companionID)
        await #expect(throws: AteWithError.gone) { try await model.post() }
        #expect(model.phase == .gone)
    }

    @Test func answeredOpensTheirEntryAndDeclinedIsGone() async throws {
        let answered = Fixture.tag(minutesAgo: 1)
        let declined = Fixture.tag(minutesAgo: 2)
        let service = InMemoryNotifications(tags: [answered, declined])
        let answeredID = try #require(answered.notification.companionID)
        let declinedID = try #require(declined.notification.companionID)
        let first = AteWithRespondModel(companionID: answeredID, service: service)
        await first.load()
        let posted = try await service.respond(
            companionID: answeredID, entryID: first.entryID,
            items: [AteWithItem(dishID: Fixture.ragu.dishID, score: nil)], body: ""
        )
        let reopened = AteWithRespondModel(companionID: answeredID, service: service)
        await reopened.load()
        #expect(reopened.phase == .answered(posted.id))

        try await service.decline(companionID: declinedID)
        let model = AteWithRespondModel(companionID: declinedID, service: service)
        await model.load()
        #expect(model.phase == .gone)
        await #expect(throws: AteWithError.declined) {
            try await service.respond(companionID: declinedID, entryID: UUID(), items: [], body: "Hi")
        }
    }

    @Test func dishesStillSortingAreAskedForAgain() async throws {
        let tag = Fixture.tag(minutesAgo: 1, sortStatus: .pending, dishes: [])
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag])
        let model = AteWithRespondModel(companionID: companionID, service: service, pollInterval: .zero, maxPolls: 2)
        await model.load()
        #expect(model.phase == .loading, "still the skeleton, never 'no dishes'")
    }

    @Test func wordsAloneArePostableAndUnscoredStaysEmpty() async throws {
        let tag = Fixture.tag(minutesAgo: 1)
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag])
        let model = AteWithRespondModel(companionID: companionID, service: service)
        await model.load()
        model.body = "  Stole half his pasta.  "
        let card = try await model.post()
        #expect(card.body == "Stole half his pasta.")
        #expect(card.items.allSatisfy { $0.score == nil }, "never inferred")
        #expect(card.avgScore == nil)
    }
}
