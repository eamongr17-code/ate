import Foundation

/// **One row of `my_notifications`** (0058) — somebody ate with you. In V1 this is the only kind
/// there is: `type` is `ate_with`, and a row of any other type is not rendered (the page filters it,
/// ``isRenderable``).
public struct AteNotification: Sendable, Hashable, Identifiable, Decodable {
    public let id: UUID
    public let type: String
    public let createdAt: Date
    public let readAt: Date?
    public let actor: Person
    public let companionID: UUID?
    public let companionStatus: AteWithStatus?
    public let entryID: UUID?
    /// The tagger's place. `nil` only if the place itself has gone — a tag needs one to be made.
    public let place: Place?
    /// The visit: the tagger's entry's own time, not the moment of the tag.
    public let visitedAt: Date?

    public struct Person: Sendable, Hashable, Decodable {
        public let id: UUID
        public let username: String
        public let name: String?
        public let avatarURL: String?

        public init(id: UUID, username: String, name: String? = nil, avatarURL: String? = nil) {
            self.id = id
            self.username = username
            self.name = name
            self.avatarURL = avatarURL
        }

        enum CodingKeys: String, CodingKey {
            case id, username, name
            case avatarURL = "avatar_url"
        }
    }

    public struct Place: Sendable, Hashable, Decodable {
        public let id: UUID
        public let name: String
        public let locality: String?

        public init(id: UUID, name: String, locality: String? = nil) {
            self.id = id
            self.name = name
            self.locality = locality
        }
    }

    // A wide row deserves a wide initialiser.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        id: UUID,
        type: String = AteNotification.ateWith,
        createdAt: Date,
        readAt: Date? = nil,
        actor: Person,
        companionID: UUID?,
        companionStatus: AteWithStatus? = .pending,
        entryID: UUID?,
        place: Place?,
        visitedAt: Date?
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.readAt = readAt
        self.actor = actor
        self.companionID = companionID
        self.companionStatus = companionStatus
        self.entryID = entryID
        self.place = place
        self.visitedAt = visitedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, actor, place
        case createdAt = "created_at"
        case readAt = "read_at"
        case companionID = "companion_id"
        case companionStatus = "companion_status"
        case entryID = "entry_id"
        case visitedAt = "visited_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        actor = try container.decode(Person.self, forKey: .actor)
        companionID = try container.decodeIfPresent(UUID.self, forKey: .companionID)
        // An unknown status is not a reason to drop the row.
        companionStatus = (try? container.decodeIfPresent(String.self, forKey: .companionStatus))
            .flatMap { $0.flatMap(AteWithStatus.init(rawValue:)) }
        entryID = try container.decodeIfPresent(UUID.self, forKey: .entryID)
        place = try container.decodeIfPresent(Place.self, forKey: .place)
        visitedAt = try container.decodeIfPresent(Date.self, forKey: .visitedAt)
    }

    /// The one type V1 draws.
    public static let ateWith = "ate_with"

    /// Drawn: an `ate_with` row that points at a tag.
    public var isRenderable: Bool { type == Self.ateWith && companionID != nil }

    public var isUnread: Bool { readAt == nil }

    /// Where the next page starts: both halves of the keyset, from this row.
    public var cursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }
}

/// A tag's state, as `entry_companions.status` writes it.
public enum AteWithStatus: String, Sendable, Hashable, Codable {
    case pending, accepted, declined
}

/// One page of notifications and where the next starts (`nil` once the stream is spent).
public struct NotificationPage: Sendable {
    public let items: [AteNotification]
    public let nextCursor: PageCursor?

    public init(items: [AteNotification], nextCursor: PageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// A short read is the last page.
    public init(items: [AteNotification], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.cursor
    }
}
