import Foundation

/// **A saved dish**, as `my_saved_dishes` hands it over: the dish, where it is served, what everyone
/// scored it, and — the part that makes it worth having — whose entry it came from.
///
/// `restaurantName` is a display string and never an identifier: everything keys on `dishID` and
/// `restaurantID` (ARCHITECTURE.md — UUID keys everywhere).
public struct SavedDish: Sendable, Hashable, Codable, Identifiable {
    public let dishID: UUID
    public let dishName: String
    public let restaurantID: UUID
    public let restaurantName: String
    public let restaurantCity: String?
    /// The dish's community aggregate — `nil` when nobody has scored it (design rule 7: an empty
    /// star, never a zero).
    public let dishScore: Double?
    public let dishCoverURL: String?
    /// Provenance: the entry this was saved from, and whose it was. `nil` when the author is blocked
    /// or gone — you keep what you saved, it just loses its "from @…".
    public let sourceEntryID: UUID?
    public let sourceUserID: UUID?
    public let sourceUsername: String?
    public let savedAt: Date

    public var id: UUID { dishID }

    public init(
        dishID: UUID,
        dishName: String,
        restaurantID: UUID,
        restaurantName: String,
        restaurantCity: String? = nil,
        dishScore: Double? = nil,
        dishCoverURL: String? = nil,
        sourceEntryID: UUID? = nil,
        sourceUserID: UUID? = nil,
        sourceUsername: String? = nil,
        savedAt: Date
    ) {
        self.dishID = dishID
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.restaurantCity = restaurantCity
        self.dishScore = dishScore
        self.dishCoverURL = dishCoverURL
        self.sourceEntryID = sourceEntryID
        self.sourceUserID = sourceUserID
        self.sourceUsername = sourceUsername
        self.savedAt = savedAt
    }

    enum CodingKeys: String, CodingKey {
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantCity = "restaurant_city"
        case dishScore = "dish_score"
        case dishCoverURL = "dish_cover_url"
        case sourceEntryID = "source_entry_id"
        case sourceUserID = "source_user_id"
        case sourceUsername = "source_username"
        case savedAt = "saved_at"
    }
}

extension SavedDish: KeysetPaginated {
    public static let table = "my_saved_dishes"
    public static let columns = "*"
    public static let primaryKeyColumn = "dish_id"
    /// The view has no `id`/`created_at` pair, so the cursor is built from the two columns that do
    /// make a total order: when it was saved, and which dish.
    public var pageCursor: PageCursor { PageCursor(createdAt: savedAt, id: dishID) }
}

/// One place's worth of saved dishes — the design groups the Saved shelf by place, and grouping is
/// presentation, so it happens here rather than on the wire.
public struct SavedDishGroup: Sendable, Hashable, Identifiable {
    public let restaurantID: UUID
    public let restaurantName: String
    public let city: String?
    public let dishes: [SavedDish]

    public var id: UUID { restaurantID }

    public init(restaurantID: UUID, restaurantName: String, city: String?, dishes: [SavedDish]) {
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.city = city
        self.dishes = dishes
    }
}

public enum SavedDishGrouping {
    /// Groups by place, keeping the order the rows arrived in — newest save first, and a place keeps
    /// the position its most recently saved dish gave it. Deliberately not alphabetical: the list is
    /// a shortlist of what to eat next, and the thing you just saved belongs at the top of it.
    ///
    /// A group split across a page boundary is rejoined here, because every mutation ends in this
    /// function — the same rule the journal's day grouping follows.
    public static func groups(from dishes: [SavedDish]) -> [SavedDishGroup] {
        var order: [UUID] = []
        var grouped: [UUID: [SavedDish]] = [:]
        for dish in dishes {
            if grouped[dish.restaurantID] == nil { order.append(dish.restaurantID) }
            grouped[dish.restaurantID, default: []].append(dish)
        }
        return order.compactMap { id in
            guard let rows = grouped[id], let first = rows.first else { return nil }
            return SavedDishGroup(
                restaurantID: id,
                restaurantName: first.restaurantName,
                city: first.restaurantCity,
                dishes: rows
            )
        }
    }
}
