import Foundation

/// **A person the picker can tag** — a handle, the name under it, an avatar. Who they are on Ate,
/// keyed by their id; the handle is only what is printed.
public struct CompanionPerson: Sendable, Hashable, Codable, Identifiable {
    public let userID: UUID
    public let handle: String
    public let name: String?
    public let avatarURL: String?

    public var id: UUID { userID }

    public init(userID: UUID, handle: String, name: String? = nil, avatarURL: String? = nil) {
        self.userID = userID
        self.handle = handle
        self.name = name
        self.avatarURL = avatarURL
    }

    /// Somebody already on an entry — what an edit opens the picker holding.
    public init(_ companion: EntryCompanion) {
        self.init(userID: companion.userID, handle: companion.username, name: companion.name,
                  avatarURL: companion.avatarURL)
    }

    init(_ row: SearchPersonRow) {
        self.init(userID: row.userID, handle: row.username, name: row.name.isEmpty ? nil : row.name,
                  avatarURL: row.avatarURL)
    }

    /// Accent- and case-insensitive, on the handle or the name — the local filter over recents
    /// before a query is long enough to go to the server.
    func matches(_ query: String) -> Bool {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard needle.isEmpty == false else { return true }
        return [handle, name ?? ""].contains { hay in
            hay.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
        }
    }
}
