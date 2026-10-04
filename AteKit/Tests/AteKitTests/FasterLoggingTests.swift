import Foundation
import Testing
@testable import AteKit

/// Build 87, note 11 — the app's half of faster logging (0056): the sort starts the moment the words
/// land, its reply's `entry_card` prints with no re-read, and a reply without one is read as before.
private final class TimedEntryService: EntryService, TestFake, @unchecked Sendable {
    var carriesCard = true
    private let lock = NSLock()
    private var calls: [String] = []
    private var cards: [UUID: EntryCard] = [:]

    var log: [String] { lock.withLock { calls } }
    private func note(_ call: String) { lock.withLock { calls.append(call) } }

    func authorID() async throws -> UUID { ViewerProfile.preview.id }

    func create(_ entry: NewEntry) async throws -> EntryCard {
        try await insert(entry)
        return try await self.entry(id: entry.id)
    }

    func insert(_ entry: NewEntry) async throws {
        note("insert")
        lock.withLock {
            cards[entry.id] = EntryCard(id: entry.id, authorID: entry.authorID, body: entry.body,
                                        restaurantID: entry.restaurantID, orderNumber: 143, createdAt: entry.createdAt)
        }
    }

    func entry(id: UUID) async throws -> EntryCard {
        note("read")
        return try lock.withLock {
            guard let card = cards[id] else { throw AteAPIError.notFound(table: "entry_cards", id: id) }
            return card
        }
    }

    func attach(photo: EntryPhotoUpload) async throws { note("photo") }

    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        note("sort")
        let sorted = EntryCard(id: entryID, authorID: ViewerProfile.preview.id, body: "the tiramisu was a 4",
                               orderNumber: 143, sortStatus: .sorted, createdAt: Date(),
                               items: [EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu",
                                                      score: Rating(rounding: 4), position: 0)])
        return SortOutcome(entryID: entryID, status: .sorted, mode: "model", itemCount: 1, restaurantID: nil,
                           didAttachPlace: false, card: carriesCard ? sorted : nil)
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EntryCard??
    func set(_ card: EntryCard?) { lock.withLock { value = .some(card) } }
    var card: EntryCard?? { lock.withLock { value } }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String]?
    func set(_ value: [String]) { lock.withLock { calls = value } }
    var value: [String]? { lock.withLock { calls } }
}

@Suite("Faster logging")
struct FasterLoggingTests {
    private func request() -> NewEntryRequest {
        NewEntryRequest(id: UUID(), body: "the tiramisu was a 4", restaurantID: UUID(), photoPaths: [],
                        createdAt: Date(), scoreCount: 1, secondsFromOpen: 9)
    }

    @Test("the sort may start the moment the insert lands, before the row is read back")
    func insertedBeforeRead() async {
        let service = TimedEntryService()
        let submission = EntrySubmission(entries: service, outbox: EntryOutbox(entries: service,
                                                                              containerName: "Tests-\(UUID())"))
        let atTold = Calls()
        let result = await submission.submit(request()) {
            // What the service had been asked when the composer was told.
            atTold.set(service.log)
        }
        #expect(atTold.value == ["insert"], "told after the insert, before the read")
        #expect(service.log == ["insert", "read"])
        #expect(result.card?.orderNumber == 143, "the order number the skeleton prints is the server's")
    }

    @Test("the sort's own card prints: no re-read before the sorted signal")
    func replyCardPrints() async throws {
        let service = TimedEntryService()
        let submission = EntrySubmission(entries: service, outbox: EntryOutbox(entries: service,
                                                                              containerName: "Tests-\(UUID())"))
        let heard = Heard()
        let id = UUID()
        try await service.insert(NewEntry(id: id, authorID: ViewerProfile.preview.id, body: "x", restaurantID: nil,
                                      createdAt: Date()))
        let before = service.log.count
        await submission.finish(entryID: id, photoPaths: []) { heard.set($0) }
        #expect(heard.card??.items.map(\.dishName) == ["Tiramisu"])
        // One read remains, after the signal: the photos' confirmation.
        #expect(Array(service.log.dropFirst(before)) == ["sort", "read"])
    }

    @Test("a reply without a card is read, as before")
    func noCardReads() async throws {
        let service = TimedEntryService()
        service.carriesCard = false
        let submission = EntrySubmission(entries: service, outbox: EntryOutbox(entries: service,
                                                                              containerName: "Tests-\(UUID())"))
        let heard = Heard()
        let id = UUID()
        try await service.insert(NewEntry(id: id, authorID: ViewerProfile.preview.id, body: "x", restaurantID: nil,
                                      createdAt: Date()))
        let before = service.log.count
        await submission.finish(entryID: id, photoPaths: []) { heard.set($0) }
        #expect(heard.card??.orderNumber == 143)
        #expect(Array(service.log.dropFirst(before)) == ["sort", "read", "read"])
    }

    @Test("the sort reply's entry_card decodes; one this build cannot read is nil, not a failure")
    func decodesReplyCard() throws {
        let id = UUID().uuidString.lowercased(), author = UUID().uuidString.lowercased()
        let card = """
        {"id":"\(id)","author_id":"\(author)","body":"the tiramisu was a 4","visibility":"public",
         "restaurant_id":null,"restaurant_source":null,"order_number":143,"sort_status":"sorted",
         "sorted_at":"2026-10-04T09:00:00.123456+00:00","created_at":"2026-10-04T09:00:00.123456+00:00",
         "updated_at":"2026-10-04T09:00:00.123456+00:00","is_mine":true,"author":null,"place":null,
         "photos":[],"photo_count":0,"items":[],"dish_count":0,"avg_score":null}
        """
        let reply = Data(#"{"ok":true,"mode":"model","sort_status":"sorted","items":[],"entry_card":\#(card)}"#.utf8)
        let decoded = try SupabaseEntryService.decodeSortResponse(reply)
        #expect(decoded.entryCard?.card?.orderNumber == 143)
        let broken = Data(#"{"ok":true,"mode":"model","entry_card":{"id":"nope"}}"#.utf8)
        #expect(try SupabaseEntryService.decodeSortResponse(broken).entryCard?.card == nil)
        let absent = Data(#"{"ok":true,"mode":"stub","entry_card":null}"#.utf8)
        #expect(try SupabaseEntryService.decodeSortResponse(absent).entryCard == nil)
    }

    @Test("summary_receipt_entered carries the time from Done and whether the preview matched")
    func timingEvent() {
        let id = UUID()
        let event = EntryEvents.summaryReceiptEntered(entryID: id, waitMilliseconds: 120,
                                                      millisecondsFromDone: 1840, cacheHit: true)
        #expect(event.name == "summary_receipt_entered")
        #expect(event.parameters["ms_from_done"] == "1840")
        #expect(event.parameters["cache_hit"] == "true")
        #expect(EntryEvents.summaryReceiptEntered(entryID: id, waitMilliseconds: 0).parameters["ms_from_done"] == nil)
    }
}
