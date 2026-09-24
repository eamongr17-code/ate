import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// Calling an RPC the way the app has to call it, for the contract suites.
///
/// Two things it exists to get right, both of which have bitten this codebase:
/// - **Decoding from the response's own bytes through ``PostgRESTDate/decoder``**, never the
///   client's default decoder. Postgres keeps microseconds and a millisecond-truncated `Date` is a
///   keyset cursor that matches nothing.
/// - **Naming every parameter.** PostgREST sends named arguments, so a contract test that omits one
///   proves the default exists too — and a second overload of the same function would fail here with
///   `42725` rather than in front of a user (data-model landmine 7).
enum StagingRPC {
    static func rows<Row: Decodable & Sendable>(
        _ client: AteAPIClient,
        _ function: String,
        _ parameters: [String: AnyJSON] = [:],
        as type: Row.Type = Row.self
    ) async throws -> [Row] {
        let data = try await client.supabase.rpc(function, params: parameters).execute().data
        return try PostgRESTDate.decoder.decode([Row].self, from: data)
    }

    /// A scalar- or object-returning RPC (`monthly_statement` is one jsonb, not a set).
    static func value<Value: Decodable & Sendable>(
        _ client: AteAPIClient,
        _ function: String,
        _ parameters: [String: AnyJSON] = [:],
        as type: Value.Type = Value.self
    ) async throws -> Value {
        let data = try await client.supabase.rpc(function, params: parameters).execute().data
        return try PostgRESTDate.decoder.decode(Value.self, from: data)
    }

    /// The raw body, for a boolean RPC: the wire text *is* the contract (`true` / `false`).
    static func raw(
        _ client: AteAPIClient,
        _ function: String,
        _ parameters: [String: AnyJSON] = [:]
    ) async throws -> String {
        let data = try await client.supabase.rpc(function, params: parameters).execute().data
        let text = String(bytes: data, encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func id(_ value: UUID) -> AnyJSON { .string(value.uuidString.lowercased()) }
    static func at(_ value: Date) -> AnyJSON { .string(PostgRESTTimestamp.string(from: value)) }
    static func text(_ value: String?) -> AnyJSON { value.map { AnyJSON.string($0) } ?? .null }
    static func number(_ value: Double?) -> AnyJSON { value.map { AnyJSON.double($0) } ?? .null }
    static func count(_ value: Int?) -> AnyJSON { value.map { AnyJSON.integer($0) } ?? .null }
    static func maybeID(_ value: UUID?) -> AnyJSON { value.map { id($0) } ?? .null }
    static func maybeAt(_ value: Date?) -> AnyJSON { value.map { at($0) } ?? .null }
}

/// Comparing a paged walk against the same read taken whole, **on a database that is not standing
/// still.**
///
/// Staging is shared and the contract suites run in parallel with each other.
/// `SocialContractTests.blockingHidesThem` blocks a seeded author for the length of one test, and
/// `blocked_with()` then hides that author's profile, entries AND reviews from every read — so a row
/// that really was in the first page of fifty can legitimately be gone by the time a walk in pages of
/// two reaches it. (`StagingContractTests` learned the same lesson from the other direction: rows
/// ARRIVE mid-walk too.) A plain `walked == whole` turns that into a red suite that says "the cursor
/// is broken" when the cursor is perfect — and a contract suite that cries wolf is how a real
/// breakage gets ignored.
///
/// **The trap this went through once:** intersecting with the WALK (`Set(walked) ∩ whole`) makes the
/// assertion unfalsifiable — a row the cursor drops is missing from `walked`, so it leaves the
/// intersection and the comparison passes. That removes exactly the failure the test exists for.
/// The stable set has to be established by the DATABASE, not by the walk's own output.
///
/// So `whole` is read TWICE, before and after the walk, and the contract is:
///  1. **the walk repeats nothing** — the same row twice is a cursor that failed to advance;
///  2. **every row that existed throughout (`before ∩ after`) appears in the walk, in `before`'s
///     relative order** — a dropped row is in the stable set and not in the walk, so a skip fails;
///     so does a reorder. Rows that only left, or only arrived, fall out of the stable set by
///     construction and can no longer make a correct cursor look broken.
enum KeysetWalk {
    static func expectMatches<ID: Hashable>(
        _ walked: [ID],
        before: [ID],
        after: [ID],
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            Set(walked).count == walked.count,
            "the \(what) cursor served a row twice",
            sourceLocation: sourceLocation
        )
        let stable = Set(before).intersection(after)
        let expected = before.filter { stable.contains($0) }
        let got = walked.filter { stable.contains($0) }
        #expect(
            got == expected,
            """
            the \(what) cursor skipped or reordered a row that was there the whole time \
            (\(expected.count) stable, \(got.count) of them walked; \(walked.count) walked in all)
            """,
            sourceLocation: sourceLocation
        )
    }
}
