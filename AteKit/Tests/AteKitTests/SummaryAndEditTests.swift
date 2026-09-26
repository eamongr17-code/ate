import Foundation
import Testing
@testable import AteKit

/// Hands out the given rows in order, then keeps repeating the last; `nil` is a failed read.
private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [EntryCard?]
    private(set) var calls = 0
    init(_ rows: [EntryCard?]) { self.rows = rows }
    func next() throws -> EntryCard {
        try lock.withLock {
            calls += 1
            let row = rows.count > 1 ? rows.removeFirst() : rows.first.flatMap { $0 }
            guard let row else { throw AteAPIError.notFound(table: "entry_cards", id: UUID()) }
            return row
        }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ entry: String) { lock.withLock { log.append(entry) } }
    var all: [String] { lock.withLock { log } }
}

private let tipo = EntryCard.Place(id: UUID(), name: "Tipo 00", address: "361 Little Bourke St")

private func card(_ status: EntrySortStatus, id: UUID = UUID(), place: EntryCard.Place? = tipo,
                  lines: Int = 1) -> EntryCard {
    EntryCard(
        id: id, authorID: UUID(), body: "The ragù 4.5.", restaurantID: place?.id, orderNumber: 142,
        sortStatus: status, createdAt: Date(timeIntervalSince1970: 1_789_000_000), place: place,
        items: (0..<lines).map { EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Ragù",
                                                 score: Rating(exactly: 4.5), position: $0 + 1) }
    )
}

@MainActor
private func store(
    _ start: EntryCard,
    fetch: @escaping @Sendable (UUID) throws -> EntryCard,
    correctPlace: @escaping @Sendable (UUID, UUID) throws -> EntryCard = { id, _ in card(.sorted, id: id) },
    resort: @escaping @Sendable (UUID) throws -> Void = { _ in },
    maxPolls: Int = 10
) -> EntrySummaryStore {
    EntrySummaryStore(
        card: start, pollInterval: .zero, maxPolls: maxPolls,
        actions: EntrySummaryStore.Actions(
            fetch: { try fetch($0) },
            correctPlace: { try correctPlace($0, $1) },
            resort: { try resort($0) }
        )
    )
}

@Suite("The Summary after Done")
@MainActor
struct EntrySummaryStoreTests {

    @Test("it prints the moment the sorter answers, and stops asking")
    func printsWhenSorted() async {
        let id = UUID()
        let replies = Replies([card(.pending, id: id), nil, card(.sorted, id: id), card(.sorted, id: id)])
        let summary = store(card(.pending, id: id)) { _ in try replies.next() }
        #expect(summary.phase == .sorting)
        await summary.watch()
        #expect(summary.phase == .printed)
        #expect(replies.calls == 3, "a failed read is one more wait; the sorted row ends it")
    }

    @Test("a placeless entry sorts to nothing, and never prints or shares an empty receipt")
    func placelessNeverPrints() async {
        let id = UUID()
        // 0036: no place → sort_status 'sorted', no reviews, the plan parked.
        let parked = card(.sorted, id: id, place: nil, lines: 0)
        let summary = store(card(.pending, id: id, place: nil, lines: 0)) { _ in parked }
        await summary.watch()
        #expect(summary.phase == .needsPlace)
        #expect(summary.share() == nil, "nothing to send")
        #expect(summary.done()?.parameters["printed"] == "false", "and Done does not claim it printed")
    }

    @Test("attaching a place applies the parked plan and the receipt prints with its dishes")
    func attachingAPlacePrints() async {
        let id = UUID()
        let parked = card(.sorted, id: id, place: nil, lines: 0)
        let attached = Calls()
        let summary = store(parked, fetch: { _ in parked }, correctPlace: { entry, place in
            attached.add("\(entry)|\(place)")
            return card(.sorted, id: entry, lines: 2)
        })
        #expect(summary.phase == .needsPlace)
        await summary.attachPlace(tipo.id)
        #expect(attached.all == ["\(id)|\(tipo.id)"])
        #expect(summary.phase == .printed)
        #expect(summary.card.items.count == 2)
        #expect(summary.share() != nil, "Share is live once it has printed")
    }

    @Test("a place with no dish on it is not an empty receipt either: it stalls, with a re-print")
    func placeButNoLines() async {
        let summary = store(card(.pending, place: tipo, lines: 0)) { _ in card(.sorted, lines: 0) }
        await summary.watch()
        #expect(summary.phase == .stalled)
        #expect(summary.share() == nil)
    }

    @Test("a stalled print recovers: Print it again re-sorts and watches, and Done is still there")
    func stalledRecovers() async {
        let id = UUID()
        let resorted = Calls()
        let replies = Replies([card(.pending, id: id)])
        let summary = store(card(.pending, id: id), fetch: { _ in try replies.next() },
                            resort: { resorted.add("\($0)") }, maxPolls: 3)
        await summary.watch()
        #expect(summary.phase == .stalled, "the give-up")

        let fixed = EntrySummaryStore(
            card: summary.card, pollInterval: .zero, maxPolls: 3,
            actions: .init(fetch: { _ in card(.sorted, id: id) }, correctPlace: { _, _ in card(.sorted) },
                           resort: { resorted.add("\($0)") })
        )
        // A failed row stalls straight away; the re-print is the way out.
        let failed = EntrySummaryStore(
            card: card(.failed, id: id), pollInterval: .zero,
            actions: .init(fetch: { _ in card(.sorted, id: id) }, correctPlace: { _, _ in card(.sorted) },
                           resort: { resorted.add("\($0)") })
        )
        #expect(failed.phase == .stalled)
        await failed.reprint()
        #expect(resorted.all == ["\(id)"])
        #expect(failed.phase == .printed)
        #expect(fixed.done() != nil, "Done works whatever the receipt is doing")
    }

    @Test("Done counts once, and Share counts once per sheet, however fast the taps")
    func doubleTaps() async {
        let summary = store(card(.sorted)) { _ in card(.sorted) }
        #expect(summary.share()?.name == "summary_shared")
        #expect(summary.share() == nil, "a second tap while the sheet is up")
        summary.shareEnded()
        #expect(summary.share() != nil, "the next sheet is a new share")
        summary.shareEnded()
        #expect(summary.done()?.name == "summary_done")
        #expect(summary.done() == nil, "a second Done on a screen already leaving")
        #expect(summary.share() == nil, "and nothing after Done")
    }

    @Test("summary events name their entry; receipt_shared says it came from the Summary")
    func events() {
        let id = UUID()
        #expect(EntryEvents.summaryShared(entryID: id).parameters["entry_id"] == id.uuidString.lowercased())
        #expect(EntryEvents.summaryDone(entryID: id, wasPrinted: true).parameters["printed"] == "true")
        #expect(EntryEvents.receiptShared(entryID: id, source: .summary).parameters["source"] == "summary")
    }
}

// MARK: - Editing

/// Records what an edit asked the server to do, in order.
private final class EditRecorder: EntryService, @unchecked Sendable {
    let calls = Calls()
    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { UUID() }
    func create(_ entry: NewEntry) async throws -> EntryCard { card(.pending) }
    func attach(photo: EntryPhotoUpload) async throws {}
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        calls.add("sort force=\(force) tags=\(tagTokens.map { "\($0.offset):\($0.length)" })")
        return SortOutcome(entryID: entryID, status: .sorted, mode: "stub", itemCount: 1,
                           restaurantID: nil, didAttachPlace: false)
    }
    func entry(id: UUID) async throws -> EntryCard { card(.sorted, id: id) }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        Page(items: [], requestedLimit: pageSize)
    }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard {
        calls.add("place \(restaurantID)")
        return card(.sorted, id: entryID)
    }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func setTags(reviewID: UUID, tags: [DietTag]) async throws {}
    func updateBody(entryID: UUID, body: String) async throws { calls.add("body \(body)") }
}

@Suite("Editing an entry keeps what the keys set")
struct EntryEditTests {
    private let id = UUID()

    @Test("a place picked on the Place key while editing is attached, after the words")
    func placeChange() async throws {
        let recorder = EditRecorder()
        let newPlace = UUID()
        let edit = EntryEdit(entryID: id, body: "Tiramisu 3.0", originalRestaurantID: UUID(),
                             restaurantID: newPlace, tagTokens: [])
        _ = try await edit.saveWordsAndPlace(to: recorder)
        await edit.sort(on: recorder)
        #expect(recorder.calls.all == ["body Tiramisu 3.0", "place \(newPlace)", "sort force=false tags=[]"])
    }

    @Test("the same place, or none, is not a correction")
    func noPlaceChange() async throws {
        let place = UUID()
        let same = EntryEdit(entryID: id, body: "x", originalRestaurantID: place, restaurantID: place, tagTokens: [])
        let none = EntryEdit(entryID: id, body: "x", originalRestaurantID: place, restaurantID: nil, tagTokens: [])
        #expect(same.changesPlace == false)
        #expect(none.changesPlace == false)
    }

    @Test("tag chips typed while editing reach the server: a forced re-sort carrying tag_tokens")
    func tagChipsResort() async throws {
        let recorder = EditRecorder()
        let words = EntryComposition(plain: "Tiramisu v 3.0", spans: [
            EntryTokenSpan(token: EntryToken(kind: .tag(DietTagMark(.v))), span: TextSpan(location: 9, length: 1))
        ])
        let edit = EntryEdit(entryID: id, body: words.plain, originalRestaurantID: nil, restaurantID: nil,
                             tagTokens: words.tagTokens)
        _ = try await edit.saveWordsAndPlace(to: recorder)
        await edit.sort(on: recorder)
        #expect(recorder.calls.all == ["body Tiramisu v 3.0", "sort force=true tags=[\"9:1\"]"])
    }
}

@Suite("The slider's title")
struct SliderTitleTests {
    @Test("a score opened straight after a tag chip is titled with the dish, not the chip")
    func skipsTheChip() throws {
        let text = "Tiramisu v 3.0"
        let tag = EntryToken(kind: .tag(DietTagMark(.v)))
        let score = EntryToken(kind: .score(Rating(exactly: 3)!))
        let words = EntryComposition(plain: text, spans: [
            EntryTokenSpan(token: tag, span: TextSpan(location: 9, length: 1)),
            EntryTokenSpan(token: score, span: TextSpan(location: 11, length: 3))
        ])
        #expect(words.dishWords(beforeTokenID: score.id) == "Tiramisu")
    }

    @Test("an earlier score's digits are never read as a name")
    func stopsAtAScore() {
        let first = EntryToken(kind: .score(Rating(exactly: 0.5)!))
        let second = EntryToken(kind: .score(Rating(exactly: 0.5)!))
        let words = EntryComposition(plain: "The ragù 0.5 0.5", spans: [
            EntryTokenSpan(token: first, span: TextSpan(location: 9, length: 3)),
            EntryTokenSpan(token: second, span: TextSpan(location: 13, length: 3))
        ])
        #expect(words.dishWords(beforeTokenID: second.id) == nil)
        #expect(words.dishWords(beforeTokenID: first.id) == "The ragù")
    }
}
