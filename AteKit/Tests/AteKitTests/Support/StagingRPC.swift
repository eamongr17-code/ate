import Foundation
import PostgREST
import Supabase

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
