import Foundation

@testable import AteKit

// Test-only wire shapes for reads the app does not model: `search_all`'s row and the account/blocks
// reads (migrations 0031, 0032). The four Search scopes and Nearby are decoded with AteKit's own
// rows (`Search/SearchWire.swift`, promoted by the Search lane) — one type, so the contract tests pin
// exactly what the app decodes. Nothing here has a forgiving decoder.
//
// The two standing rules:
//   * an AGGREGATE is a `Double` (4.3 is a legal average and an illegal score); a USER'S score would
//     be a `Rating`, and none of these rows carries one.
//   * anything the server can legitimately not know is Optional — a cuisine nobody set, a locality we
//     cannot name, a dish nobody scored. Absent is never `""` and never `0`.

// MARK: - search_all (unchanged shape, the composer's place sheet reads it)

struct SearchAllWireRow: Decodable, Sendable {
    let kind: String
    let id: UUID
    let title: String
    let subtitle: String?
    let score: Double?
    let matchRank: Double?
    let detail: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case kind, id, title, subtitle, score, detail
        case matchRank = "match_rank"
    }
}

/// Just enough to assert a `detail` key exists and is (or is not) null — the jsonb bag is documented
/// per kind and deliberately not modelled.
enum AnyCodableValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .other
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
}

// MARK: - Account + blocks (0032)

/// `my_blocks` — design/v1/Settings' blocked list. The profile fields come through a DEFINER read
/// because the `profiles` policy hides exactly these people from exactly this viewer.
struct MyBlockRow: Decodable, Sendable {
    let blockedID: UUID
    let username: String?
    let name: String?
    let avatarURL: String?
    let city: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case username, name, city
        case blockedID = "blocked_id"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
    }
}

/// `delete_account` — `{ok, auth_user_deleted}`. `auth_user_deleted == false` means the data is gone
/// but the auth row survived and the account can still be signed into: report it, do not ignore it.
struct DeleteAccountResult: Decodable, Sendable {
    let ok: Bool
    let authUserDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case authUserDeleted = "auth_user_deleted"
    }
}
