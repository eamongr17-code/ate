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

    /// A tag at Tipo 00 with three dishes, for someone who already posted there that day.
    static func tag(myEntryID: UUID, myDishIDs: [UUID]) -> InMemoryNotifications.Tag {
        let companionID = UUID()
        let entryID = UUID()
        let visited = Date(timeIntervalSince1970: 1_789_810_200)
        return InMemoryNotifications.Tag(
            notification: AteNotification(
                id: UUID(), createdAt: visited, readAt: nil, actor: tagger, companionID: companionID,
                entryID: entryID, place: AteNotification.Place(id: place.id, name: place.name), visitedAt: visited
            ),
            prefill: AteWithPrefill(
                companionID: companionID, entryID: entryID, visitedAt: visited, tagger: tagger, place: place,
                dishes: [ragu, tiramisu, prawns], myEntryID: myEntryID, myDishIDs: myDishIDs
            )
        )
    }
}

@MainActor
@Suite("Ate with: one place, one day, one entry")
struct AteWithSameDayTests {
    @Test func prefillDecodesTheSameDayEntry() throws {
        let json = Data("""
        {"companion_id":"6f1c4b2a-0000-4000-8000-0000000000c1","status":"pending","response_entry_id":null,
         "entry_id":"6f1c4b2a-0000-4000-8000-0000000000e1","visited_at":"2026-09-19T09:30:00+00:00",
         "sort_status":"sorted",
         "tagger":{"id":"6f1c4b2a-0000-4000-8000-0000000000aa","username":"eamon","name":null,"avatar_url":null},
         "place":null,
         "dishes":[{"dish_id":"6f1c4b2a-0000-4000-8000-0000000000d2","dish_name":"Tiramisu","position":2},
                   {"dish_id":"6f1c4b2a-0000-4000-8000-0000000000d1","dish_name":"Ragù","position":1}],
         "my_entry_id":"6f1c4b2a-0000-4000-8000-0000000000e9",
         "my_dish_ids":["6f1c4b2a-0000-4000-8000-0000000000d1"]}
        """.utf8)
        let prefill = try PostgRESTDate.decoder.decode(AteWithPrefill.self, from: json)
        #expect(prefill.myEntryID?.uuidString.lowercased() == "6f1c4b2a-0000-4000-8000-0000000000e9")
        #expect(prefill.dishesToScore.map(\.dishName) == ["Tiramisu"], "the dish already on her entry is left off")
        #expect(prefill.isAlreadyScored == false)
    }

    @Test func dishesAlreadyScoredThatDayAreLeftOffAndTheAnswerJoinsHerEntry() async throws {
        let mine = UUID()
        let tag = Fixture.tag(myEntryID: mine, myDishIDs: [Fixture.ragu.dishID, Fixture.tiramisu.dishID])
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag], viewer: Fixture.viewer, firstOrderNumber: 40)
        let recorded = Recorded()
        let model = AteWithRespondModel(
            companionID: companionID, service: service, analytics: recorded.recorder, settleDelay: .zero
        )
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.lines.map(\.name) == ["Prawn spaghetti"], "only the dish she hasn't scored")
        #expect(model.current == Fixture.prawns.dishID)
        await model.finish(at: try #require(Rating(exactly: 4.5)))
        let card = try await model.post()
        #expect(card.id == mine, "into her entry that day, not a new one")
        #expect(recorded.events.last?.parameters["skipped"] == "2")
        #expect(recorded.events.last?.parameters["merged"] == "true")
    }

    @Test func everyDishAlreadyScoredOnlyLinksAndOpensHerEntry() async throws {
        let mine = UUID()
        let tag = Fixture.tag(
            myEntryID: mine, myDishIDs: [Fixture.ragu.dishID, Fixture.tiramisu.dishID, Fixture.prawns.dishID]
        )
        let companionID = try #require(tag.notification.companionID)
        let service = InMemoryNotifications(tags: [tag], viewer: Fixture.viewer, firstOrderNumber: 40)
        let recorded = Recorded()
        let model = AteWithRespondModel(companionID: companionID, service: service, analytics: recorded.recorder)
        await model.load()
        #expect(model.phase == .answered(mine), "no sheet: her entry opens")
        #expect(recorded.events.last?.name == "ate_with_linked")
        #expect(service.posted.map(\.id) == [mine])
    }
}
