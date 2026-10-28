import Foundation

/// **One award a person holds** — a row of `awards_of(p_user)` (0098).
///
/// An award is earned once and never taken away; its links (`entryID`, `dishID`) go null when the
/// entry or dish behind it is deleted, and the award stays.
public struct EarnedAward: Sendable, Hashable, Identifiable {
    public let award: PlateAward
    /// When the thing that earned it happened — the line, the entry, the save — not when it was
    /// noticed.
    public let earnedAt: Date
    public let entryID: UUID?
    public let dishID: UUID?
    /// Group awards: the entries (3 in a day, same dish 3 times) and the dishes (5 at one place,
    /// 10 saves).
    public let entryIDs: [UUID]
    public let dishIDs: [UUID]
    /// Who you ate with, or who saved it. Nil (and no handle) through a block.
    public let otherUserID: UUID?
    public let otherHandle: String?
    /// False only on your own, until the takeover has shown it.
    public let seen: Bool
    /// The line behind it — its dish on its entry, else the entry's first line.
    public let dishName: String?
    public let restaurantName: String?
    public let score: Double?

    public var id: PlateAward { award }

    public init(
        award: PlateAward,
        earnedAt: Date,
        entryID: UUID? = nil,
        dishID: UUID? = nil,
        entryIDs: [UUID] = [],
        dishIDs: [UUID] = [],
        otherUserID: UUID? = nil,
        otherHandle: String? = nil,
        seen: Bool = true,
        dishName: String? = nil,
        restaurantName: String? = nil,
        score: Double? = nil
    ) {
        self.award = award
        self.earnedAt = earnedAt
        self.entryID = entryID
        self.dishID = dishID
        self.entryIDs = entryIDs
        self.dishIDs = dishIDs
        self.otherUserID = otherUserID
        self.otherHandle = otherHandle
        self.seen = seen
        self.dishName = dishName
        self.restaurantName = restaurantName
        self.score = score
    }

    /// The entries an opened award shows: the group's, else the one that earned it.
    public var entries: [UUID] {
        if entryIDs.isEmpty == false { return entryIDs }
        return entryID.map { [$0] } ?? []
    }

    /// The line under the plate and on its back: the dish and where, and who with when there was
    /// someone. Never invented — an award with no dish behind it says only what it has.
    public var dishLine: String? {
        var line: String?
        switch (dishName, restaurantName) {
        case let (dish?, place?): line = "\(dish) at \(place)"
        case let (dish?, nil): line = dish
        case let (nil, place?): line = place
        case (nil, nil): line = nil
        }
        guard let handle = otherHandle, let base = line else { return line }
        switch award {
        case .ateWith: return "\(base), with @\(handle)"
        case .savedBySomeone: return "\(base), saved by @\(handle)"
        default: return base
        }
    }
}

extension EarnedAward: Decodable {
    enum CodingKeys: String, CodingKey {
        case award, seen, score
        case earnedAt = "earned_at"
        case entryID = "entry_id"
        case dishID = "dish_id"
        case entryIDs = "entry_ids"
        case dishIDs = "dish_ids"
        case otherUserID = "other_user_id"
        case otherHandle = "other_handle"
        case dishName = "dish_name"
        case restaurantName = "restaurant_name"
    }

    /// An id this build does not know (an award added later) is a decoding error the read skips,
    /// not one that empties the whole row — see ``AwardRows``.
    public init(from decoder: any Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        award = try row.decode(PlateAward.self, forKey: .award)
        earnedAt = try row.decode(Date.self, forKey: .earnedAt)
        entryID = try row.decodeIfPresent(UUID.self, forKey: .entryID)
        dishID = try row.decodeIfPresent(UUID.self, forKey: .dishID)
        entryIDs = try row.decodeIfPresent([UUID].self, forKey: .entryIDs) ?? []
        dishIDs = try row.decodeIfPresent([UUID].self, forKey: .dishIDs) ?? []
        otherUserID = try row.decodeIfPresent(UUID.self, forKey: .otherUserID)
        otherHandle = try row.decodeIfPresent(String.self, forKey: .otherHandle)
        seen = try row.decodeIfPresent(Bool.self, forKey: .seen) ?? true
        dishName = try row.decodeIfPresent(String.self, forKey: .dishName)
        restaurantName = try row.decodeIfPresent(String.self, forKey: .restaurantName)
        score = try row.decodeIfPresent(Double.self, forKey: .score)
    }
}

/// `awards_of`'s rows, keeping every award this build knows and skipping any it does not.
struct AwardRows: Decodable {
    let awards: [EarnedAward]

    private struct Skip: Decodable {}

    init(from decoder: any Decoder) throws {
        var rows = try decoder.unkeyedContainer()
        var out: [EarnedAward] = []
        while rows.isAtEnd == false {
            if let award = try? rows.decode(EarnedAward.self) {
                out.append(award)
            } else {
                _ = try row.decode(Skip.self)
            }
        }
        awards = out
    }
}

/// **One dish behind an opened award** — a row of `award_lines` (0098), oldest first.
public struct AwardLine: Sendable, Hashable, Identifiable, Decodable {
    public let reviewID: UUID
    public let entryID: UUID?
    public let dishID: UUID
    public let dishName: String
    public let restaurantID: UUID?
    public let restaurantName: String?
    public let score: Double?
    public let createdAt: Date
    public let photoURL: String?

    public var id: UUID { reviewID }

    public init(
        reviewID: UUID, entryID: UUID?, dishID: UUID, dishName: String, restaurantID: UUID? = nil,
        restaurantName: String? = nil, score: Double? = nil, createdAt: Date, photoURL: String? = nil
    ) {
        self.reviewID = reviewID
        self.entryID = entryID
        self.dishID = dishID
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.score = score
        self.createdAt = createdAt
        self.photoURL = photoURL
    }

    enum CodingKeys: String, CodingKey {
        case score
        case reviewID = "review_id"
        case entryID = "entry_id"
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case createdAt = "created_at"
        case photoURL = "photo_url"
    }

    /// The keyset the next page starts strictly after: `(created_at, review_id)`, ascending.
    public var cursor: PageCursor { PageCursor(createdAt: createdAt, id: reviewID) }
}
