import Foundation
import PostgREST
import Testing
@testable import AteKit

/// Postgres prints `timestamptz` with trailing zeros TRIMMED: `…:28.055990+00:00` arrives as
/// `…:28.05599+00:00`. A cursor built from a mis-decoded copy of that value skips every row that
/// ties with it — which is how the global feed walk lost four rows on staging (2026-09-24).
struct TrimmedFractionTimestampTests {
    static let cases: [(wire: String, cursor: String)] = [
        ("2026-09-02T12:34:28.05599+00:00", "2026-09-02T12:34:28.055990Z"),
        ("2026-09-02T12:34:28.0559+00:00", "2026-09-02T12:34:28.055900Z"),
        ("2026-09-02T12:34:28.5+00:00", "2026-09-02T12:34:28.500000Z"),
        ("2026-09-02T12:34:28+00:00", "2026-09-02T12:34:28.000000Z"),
        ("2026-08-30T12:30:25.240956+00:00", "2026-08-30T12:30:25.240956Z")
    ]

    @Test("the decoder the page walk uses keeps a trimmed fraction exact", arguments: cases)
    func pageDecoderRoundTrips(_ pair: (wire: String, cursor: String)) throws {
        let date = try PostgrestClient.Configuration.jsonDecoder.decode(
            Date.self, from: Data("\"\(pair.wire)\"".utf8)
        )
        #expect(PostgRESTTimestamp.string(from: date) == pair.cursor)
    }

    @Test("the house decoder keeps a trimmed fraction exact", arguments: cases)
    func houseDecoderRoundTrips(_ pair: (wire: String, cursor: String)) throws {
        let date = try PostgRESTDate.decoder.decode(Date.self, from: Data("\"\(pair.wire)\"".utf8))
        #expect(PostgRESTTimestamp.string(from: date) == pair.cursor)
    }
}
