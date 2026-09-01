import Foundation
import PostgREST
import Testing

@testable import AteKit

@Suite("Keyset pagination")
struct PaginationTests {
    static func date(_ iso: String) throws -> Date {
        // Decoded exactly as a PostgREST response would be.
        try PostgrestClient.Configuration.jsonDecoder.decode(
            Date.self, from: Data("\"\(iso)\"".utf8)
        )
    }

    @Test("a cursor timestamp keeps microsecond precision through the round trip")
    func timestampKeepsMicroseconds() throws {
        // Postgres stores microseconds and the seed lands on them. Truncating to milliseconds
        // (what ISO8601DateFormatter does) would make the `created_at.eq.<cursor>` half of the
        // keyset predicate match nothing and silently skip rows.
        let date = try Self.date("2026-08-30T12:30:25.240956+00:00")
        #expect(PostgRESTTimestamp.string(from: date) == "2026-08-30T12:30:25.240956Z")
    }

    @Test("timestamps format as UTC 'Z', never '+00:00'")
    func timestampUsesZSuffix() throws {
        // '+' survives URLComponents unescaped and would reach PostgREST as a space.
        let formatted = PostgRESTTimestamp.string(from: try Self.date("2026-08-30T12:30:25.240956+00:00"))
        #expect(formatted.hasSuffix("Z"))
        #expect(formatted.contains("+") == false)
    }

    @Test("whole seconds and the sub-microsecond carry both format cleanly", arguments: [
        ("2026-08-22T12:30:25+00:00", "2026-08-22T12:30:25.000000Z"),
        ("2026-08-22T12:30:25.5+00:00", "2026-08-22T12:30:25.500000Z"),
        ("2026-08-22T12:30:25.999999+00:00", "2026-08-22T12:30:25.999999Z")
    ])
    func timestampEdgeCases(input: String, expected: String) throws {
        #expect(PostgRESTTimestamp.string(from: try Self.date(input)) == expected)
    }

    @Test("the cursor filter expands the (created_at, id) row comparison PostgREST can't spell")
    func cursorFilterShape() throws {
        let cursor = PageCursor(
            createdAt: try Self.date("2026-08-30T12:30:25.240956+00:00"),
            id: UUID(uuidString: "c0000000-0000-4000-8000-000000000001")!
        )

        #expect(cursor.olderThanFilter() == """
        created_at.lt.2026-08-30T12:30:25.240956Z,\
        and(created_at.eq.2026-08-30T12:30:25.240956Z,id.lt.c0000000-0000-4000-8000-000000000001)
        """)
    }

    @Test("the id tiebreak is present — timestamps tie in real data")
    func cursorFilterHasTiebreak() throws {
        // Three seeded reviews share `2026-08-30T12:30:25.240956+00:00` to the microsecond. A
        // created_at-only cursor would either loop on them or drop two of them.
        let cursor = PageCursor(createdAt: try Self.date("2026-08-30T12:30:25.240956+00:00"), id: UUID())
        #expect(cursor.olderThanFilter().contains("and(created_at.eq."))
        #expect(cursor.olderThanFilter().contains("id.lt."))
    }

    @Test("page size is clamped to the server's own 1...100 range")
    func pageSizeClamped() {
        #expect(PageRequest(limit: 0).limit == 1)
        #expect(PageRequest(limit: -5).limit == 1)
        #expect(PageRequest(limit: 5_000).limit == PageRequest.maximumLimit)
        #expect(PageRequest().limit == PageRequest.defaultLimit)
    }

    @Test("a full page hands back the last row's cursor; a short page ends the stream")
    func pageAssembly() throws {
        let older = try Self.date("2026-08-29T12:30:25.240956+00:00")
        let newer = try Self.date("2026-08-30T12:30:25.240956+00:00")
        let first = Self.review(id: UUID(), createdAt: newer)
        let last = Self.review(id: UUID(), createdAt: older)

        let full = Page(items: [first, last], requestedLimit: 2)
        #expect(full.isLastPage == false)
        #expect(full.nextCursor == last.pageCursor)  // the OLDEST row, not the newest

        let short = Page(items: [first], requestedLimit: 2)
        #expect(short.isLastPage)
        #expect(short.nextCursor == nil)

        let empty = Page<Review>(items: [], requestedLimit: 2)
        #expect(empty.isEmpty)
        #expect(empty.isLastPage)
    }

    @Test("next(after:) keeps the page size and terminates on the last page")
    func requestChaining() throws {
        let request = PageRequest(limit: 2)
        let review = Self.review(id: UUID(), createdAt: try Self.date("2026-08-30T12:30:25.240956+00:00"))

        let next = request.next(after: Page(items: [review, review], requestedLimit: 2))
        #expect(next?.limit == 2)
        #expect(next?.cursor == review.pageCursor)

        #expect(request.next(after: Page(items: [review], requestedLimit: 2)) == nil)
    }

    static func review(id: UUID, createdAt: Date) -> Review {
        Review(
            id: id,
            reviewerID: UUID(),
            dishID: UUID(),
            restaurantID: UUID(),
            score: Rating(rounding: 4),
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
