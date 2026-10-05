import Foundation

/// **Somebody this entry was eaten with** — one element of `entry_cards.companions` (0058).
///
/// The server decides who is listed and to whom: an original lists its accepted companions (plus
/// pending ones, only to the author and that companion); a response lists the original's author and
/// its other accepted companions. Blocked and deactivated people are absent. The client renders what
/// arrives and never filters it again.
public struct EntryCompanion: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        case pending
        case accepted
        case declined

        /// A status this build does not know is drawn as pending — the quieter of the two it can
        /// draw — rather than costing the whole row.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .pending
        }
    }

    public let userID: UUID
    public let username: String
    public let name: String?
    public let avatarURL: String?
    public let status: Status
    /// That person's own entry for the visit (tap → `get_entry_card`); `nil` while pending.
    public let entryID: UUID?

    public var id: UUID { userID }

    public init(
        userID: UUID,
        username: String,
        name: String? = nil,
        avatarURL: String? = nil,
        status: Status = .accepted,
        entryID: UUID? = nil
    ) {
        self.userID = userID
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
        self.status = status
        self.entryID = entryID
    }

    enum CodingKeys: String, CodingKey {
        case username, name, status
        case userID = "user_id"
        case avatarURL = "avatar_url"
        case entryID = "entry_id"
    }
}

/// One element that may not decode, without taking the list down with it.
private struct LossyCompanion: Decodable {
    let value: EntryCompanion?

    init(from decoder: any Decoder) throws {
        value = try? EntryCompanion(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// **`companions` is a trailing key, `[]` never null** (0058) — but a row served by a view from
    /// before 0058, a `null`, or one malformed person must still decode as a row. The synthesized
    /// `EntryCard` decoder calls this overload for its `[EntryCompanion]` field: absent, null or
    /// unreadable is `[]`, and an unreadable element drops alone.
    func decode(_ type: [EntryCompanion].Type, forKey key: Key) throws -> [EntryCompanion] {
        guard let lossy = try? decodeIfPresent([LossyCompanion].self, forKey: key) else { return [] }
        return lossy.compactMap(\.value)
    }
}

/// **How "with" is printed.** Pure, so the receipt, the slip and the entry page agree.
public enum CompanionLine {
    /// The receipt's signature and the slip's byline: `@jess`, or `@jess +1` for two or more
    /// (`ate-with.html` 1e). `nil` with nobody to print.
    public static func compact(_ handles: [String]) -> String? {
        guard let first = handles.first else { return nil }
        let rest = handles.count - 1
        return rest > 0 ? "@\(first) +\(rest)" : "@\(first)"
    }
}
