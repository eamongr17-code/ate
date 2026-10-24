import Foundation

/// **`ate_with_prefill(p_companion_id)`** (0058) — the tagger's visit as the tagged person opens it,
/// read LIVE from the original entry: its place, its time, and its dishes, one per dish. A tag does
/// not snapshot, so this is read every time the sheet opens.
public struct AteWithPrefill: Sendable, Hashable, Decodable {
    public let companionID: UUID
    public let status: AteWithStatus
    /// Set once answered: the person's own entry, which is opened instead.
    public let responseEntryID: UUID?
    public let entryID: UUID
    public let visitedAt: Date
    /// `pending`: the tagger's dishes are still on their way (retry), not "none".
    public let sortStatus: EntrySortStatus
    public let tagger: AteNotification.Person
    public let place: Place?
    public let dishes: [Dish]
    /// The tagger's words for the visit, for "Copy their review" (0086). `nil` from an older server.
    public let body: String?

    public struct Place: Sendable, Hashable, Decodable {
        public let id: UUID
        public let name: String
        public let address: String?
        public let locality: String?

        public init(id: UUID, name: String, address: String? = nil, locality: String? = nil) {
            self.id = id
            self.name = name
            self.address = address
            self.locality = locality
        }
    }

    public struct Dish: Sendable, Hashable, Decodable, Identifiable {
        public let dishID: UUID
        public let dishName: String
        public let position: Int
        /// The tagger's score on it (0086), copied only when the person asks. Never inferred.
        public let score: Rating?

        public var id: UUID { dishID }

        public init(dishID: UUID, dishName: String, position: Int, score: Rating? = nil) {
            self.dishID = dishID
            self.dishName = dishName
            self.position = position
            self.score = score
        }

        enum CodingKeys: String, CodingKey {
            case position, score
            case dishID = "dish_id"
            case dishName = "dish_name"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dishID = try container.decode(UUID.self, forKey: .dishID)
            dishName = try container.decode(String.self, forKey: .dishName)
            position = try container.decode(Int.self, forKey: .position)
            // A score the app can't read only loses the copy, never the tag.
            score = try? container.decodeIfPresent(Rating.self, forKey: .score)
        }
    }

    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        companionID: UUID,
        status: AteWithStatus = .pending,
        responseEntryID: UUID? = nil,
        entryID: UUID,
        visitedAt: Date,
        sortStatus: EntrySortStatus = .sorted,
        tagger: AteNotification.Person,
        place: Place?,
        dishes: [Dish],
        body: String? = nil
    ) {
        self.companionID = companionID
        self.status = status
        self.responseEntryID = responseEntryID
        self.entryID = entryID
        self.visitedAt = visitedAt
        self.sortStatus = sortStatus
        self.tagger = tagger
        self.place = place
        self.dishes = dishes
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case status, tagger, place, dishes, body
        case companionID = "companion_id"
        case responseEntryID = "response_entry_id"
        case entryID = "entry_id"
        case visitedAt = "visited_at"
        case sortStatus = "sort_status"
    }

    /// The tagger's dishes are not printed yet: ask again shortly.
    public var isStillSorting: Bool { sortStatus == .pending && dishes.isEmpty }

    /// The tagger's words, trimmed; empty when there are none.
    public var taggerWords: String { (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something to copy: a score on a dish, or words.
    public var hasReviewToCopy: Bool { dishes.contains { $0.score != nil } || taggerWords.isEmpty == false }
}

/// One line of the person's own entry, as `respond_ate_with` takes it: a dish at that place, and
/// their score if they gave one. A dish left out is one they did not have.
public struct AteWithItem: Sendable, Hashable, Encodable {
    public let dishID: UUID
    public let score: Rating?

    public init(dishID: UUID, score: Rating?) {
        self.dishID = dishID
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case score
        case dishID = "dish_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dishID, forKey: .dishID)
        // Unscored is absent, never a zero.
        try container.encodeIfPresent(score?.value, forKey: .score)
    }
}

/// Why a tag could not be opened or answered — the cases the screen tells apart.
public enum AteWithError: Error, Sendable, Equatable {
    /// `P0002`: not yours, withdrawn, its entry deleted, or a block. The row simply goes.
    case gone
    /// `23505`: already answered with another entry.
    case alreadyAnswered
    /// `22023 tag_declined`: you said no to this one.
    case declined
    /// Anything else the server refused, or the network.
    case unreachable

    /// Reads a PostgREST error's code and message.
    public init(code: String?, message: String?) {
        switch code {
        case "P0002": self = .gone
        case "23505": self = .alreadyAnswered
        case "22023" where message?.contains("tag_declined") == true: self = .declined
        default: self = .unreachable
        }
    }
}
