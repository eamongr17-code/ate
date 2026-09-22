import Foundation
import Testing
@testable import AteKit

@Suite("Entry card — the one row shape")
struct EntryCardTests {

    /// The contract's own example, verbatim from `integration-design.md`.
    private let json = """
    {
      "id": "3f1b2c4d-0000-4000-8000-000000000001",
      "author_id": "5c4b0d0e-0000-4000-8000-000000000001",
      "body": "Tipo 00 with Jess. The tagliatelle al rag\\u00f9 4.5 was unreal.",
      "visibility": "public",
      "restaurant_id": "b7e00000-0000-4000-8000-000000000001",
      "restaurant_source": "user",
      "order_number": 142,
      "sort_status": "sorted",
      "sorted_at": "2026-09-19T09:41:02.240956+00:00",
      "created_at": "2026-09-19T09:40:25.240956+00:00",
      "updated_at": "2026-09-19T09:41:02.240956+00:00",
      "is_mine": true,
      "author": { "id": "5c4b0d0e-0000-4000-8000-000000000001", "username": "eamon",
                  "name": "Eamon", "avatar_url": null, "city": "Melbourne" },
      "place": { "id": "b7e00000-0000-4000-8000-000000000001", "name": "Tipo 00",
                 "address": "361 Little Bourke St", "city": "Melbourne", "cuisine": "Italian" },
      "photos": [ { "url": "https://example.test/a.jpg", "position": 0 } ],
      "photo_count": 1,
      "items": [
        { "review_id": "c7e00000-0000-4000-8000-000000000001",
          "dish_id": "d7e00000-0000-4000-8000-000000000001",
          "dish_name": "Tagliatelle al rag\\u00f9", "score": 4.5,
          "note": "unreal", "position": 1, "saved": false },
        { "review_id": "c7e00000-0000-4000-8000-000000000003",
          "dish_id": "d7e00000-0000-4000-8000-000000000003",
          "dish_name": "Prawn spaghetti", "score": null,
          "note": null, "position": 2, "saved": false }
      ],
      "dish_count": 2,
      "avg_score": 4.5
    }
    """

    @Test("decodes the contract's row, nulls and all")
    func decodesTheContractRow() throws {
        let card = try PostgRESTDate.decoder.decode(EntryCard.self, from: Data(json.utf8))

        #expect(card.orderNumber == 142)
        #expect(card.sortStatus == .sorted)
        #expect(card.visibility == .public)
        #expect(card.place?.address == "361 Little Bourke St")
        #expect(card.author?.username == "eamon")
        #expect(card.photos.map(\.position) == [0])
        #expect(card.items.count == 2)
        // DESIGN rule 7: a null score is "they gave no number", never a zero.
        #expect(card.items[0].score?.value == 4.5)
        #expect(card.items[1].score == nil)
        #expect(card.avgScore == 4.5)
    }

    @Test("the microseconds survive — a truncated cursor matches nothing")
    func microsecondsSurvive() throws {
        let card = try PostgRESTDate.decoder.decode(EntryCard.self, from: Data(json.utf8))
        let rewritten = PostgRESTTimestamp.string(from: card.createdAt)
        #expect(rewritten == "2026-09-19T09:40:25.240956Z")
    }

    @Test("the cursor is the composite (created_at, id)")
    func cursorShape() throws {
        let card = try PostgRESTDate.decoder.decode(EntryCard.self, from: Data(json.utf8))
        #expect(card.pageCursor.id == card.id)
        #expect(card.pageCursor.createdAt == card.createdAt)
    }

    @Test("the average ignores unscored lines, the way the receipt footer does")
    func averageIgnoresUnscored() {
        let items = [
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "One",
                           score: Rating(rounding: 4.5), position: 1),
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Two",
                           score: Rating(rounding: 3), position: 2),
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Three", position: 3)
        ]
        #expect(EntryCard.average(of: items) == 3.75)
        #expect(EntryCard.average(of: [items[2]]) == nil)
    }

    @Test("a pending entry has no receipt, and a sorted placeless one still has none")
    func receiptReadiness() throws {
        let card = try PostgRESTDate.decoder.decode(EntryCard.self, from: Data(json.utf8))
        #expect(card.hasReceipt)
        #expect(card.replacing(sortStatus: .pending).hasReceipt == false)
    }
}

@Suite("PostgREST timestamps")
struct PostgRESTDateTests {

    @Test("the shapes PostgREST actually emits", arguments: [
        ("2026-09-19T09:40:25.240956+00:00", 1_789_810_825.240956),
        ("2026-09-19T09:40:25.240956Z", 1_789_810_825.240956),
        ("2026-09-19T09:40:25Z", 1_789_810_825.0),
        ("2026-09-19 09:40:25.240956+00", 1_789_810_825.240956),
        // The same instant, written in Melbourne time — the offset has to be applied, not ignored.
        ("2026-09-19T19:40:25+10:00", 1_789_810_825.0)
    ])
    func parsesTheWireShapes(input: String, expected: Double) {
        let parsed = PostgRESTDate.parse(input)
        #expect(parsed != nil)
        // Within a tenth of a microsecond: `Date` is a Double and this is its resolution.
        #expect(abs((parsed?.timeIntervalSince1970 ?? 0) - expected) < 0.000_001)
    }

    @Test("nonsense is nil rather than a wrong date")
    func rejectsNonsense() {
        #expect(PostgRESTDate.parse("") == nil)
        #expect(PostgRESTDate.parse("yesterday") == nil)
        #expect(PostgRESTDate.parse("2026-09") == nil)
    }

    @Test("round trips through the cursor formatter without drift")
    func roundTrip() {
        let raw = "2026-09-19T09:40:25.240956Z"
        guard let date = PostgRESTDate.parse(raw) else {
            Issue.record("did not parse")
            return
        }
        #expect(PostgRESTTimestamp.string(from: date) == raw)
    }
}
