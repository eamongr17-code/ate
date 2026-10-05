import Foundation

/// **One of your own dish lines** — the grain a list holds (0060): the visit, and the dish on it. Not a
/// review id: a line survives a re-sort and follows a dish correction, which a review id does not.
public struct DishLine: Sendable, Hashable, Codable {
    public let entryID: UUID
    public let dishID: UUID

    public init(entryID: UUID, dishID: UUID) {
        self.entryID = entryID
        self.dishID = dishID
    }
}

/// **A list on the shelf** — `my_lists`' row, and what `create_list` / `rename_list` answer (those two
/// carry no covers; they decode as none). Private, always: `visibility` is not modelled until it can
/// be anything else.
public struct UserList: Sendable, Hashable, Identifiable, Decodable {
    public let id: UUID
    /// A display string, never a key. Duplicates are allowed.
    public let name: String
    public let itemCount: Int
    /// Up to four distinct item photos, in list order. Empty when no item has one.
    public let covers: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, name: String, itemCount: Int, covers: [String] = [], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.itemCount = max(0, itemCount)
        self.covers = Array(covers.prefix(Self.coverLimit))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, covers
        case id = "list_id"
        case itemCount = "item_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            itemCount: try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0,
            covers: (try? container.decodeIfPresent([String].self, forKey: .covers)) ?? [],
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    /// The shelf's keyset: `(created_at, list_id)`, newest first.
    public var cursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }

    public static let coverLimit = 4

    func with(name: String? = nil, itemCount: Int? = nil, covers: [String]? = nil, updatedAt: Date? = nil) -> UserList {
        UserList(
            id: id, name: name ?? self.name, itemCount: itemCount ?? self.itemCount, covers: covers ?? self.covers,
            createdAt: createdAt, updatedAt: updatedAt ?? self.updatedAt
        )
    }
}

/// **One dish on a list** — a `get_list` item. Ranked by hand: `position` is 1…n.
public struct ListItem: Sendable, Hashable, Identifiable, Decodable {
    public let id: UUID
    public let position: Int
    public let entryID: UUID
    public let dishID: UUID
    public let dishName: String
    public let restaurantID: UUID?
    public let restaurantName: String?
    /// The suburb, when the place has one to name.
    public let locality: String?
    /// That visit's own score. `nil` is unscored — an empty star, never inferred.
    public let score: Rating?
    /// The line's photo, else the visit's first photo, else none.
    public let photoURL: String?
    public let visitedAt: Date
    public let addedAt: Date

    // A wide row deserves a wide initialiser.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        id: UUID,
        position: Int,
        entryID: UUID,
        dishID: UUID,
        dishName: String,
        restaurantID: UUID? = nil,
        restaurantName: String? = nil,
        locality: String? = nil,
        score: Rating? = nil,
        photoURL: String? = nil,
        visitedAt: Date,
        addedAt: Date
    ) {
        self.id = id
        self.position = position
        self.entryID = entryID
        self.dishID = dishID
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.locality = locality
        self.score = score
        self.photoURL = photoURL
        self.visitedAt = visitedAt
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case position, locality, score
        case id = "item_id"
        case entryID = "entry_id"
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case photoURL = "photo_url"
        case visitedAt = "visited_at"
        case addedAt = "added_at"
    }

    public var line: DishLine { DishLine(entryID: entryID, dishID: dishID) }

    func at(position: Int, id: UUID? = nil) -> ListItem {
        ListItem(
            id: id ?? self.id, position: position, entryID: entryID, dishID: dishID, dishName: dishName,
            restaurantID: restaurantID, restaurantName: restaurantName, locality: locality, score: score,
            photoURL: photoURL, visitedAt: visitedAt, addedAt: addedAt
        )
    }
}

/// **A list with its items** — `get_list`. Items in order, unpaged (≤ 100).
public struct ListDetail: Sendable, Hashable, Decodable {
    public let list: UserList
    public let items: [ListItem]

    public init(list: UserList, items: [ListItem]) {
        self.list = list
        self.items = items.sorted { $0.position < $1.position }
    }

    enum CodingKeys: String, CodingKey {
        case items
    }

    public init(from decoder: any Decoder) throws {
        let items = try decoder.container(keyedBy: CodingKeys.self).decode([ListItem].self, forKey: .items)
        // `get_list` carries no covers; they are the items' own photos, the shelf's rule.
        let summary = try UserList(from: decoder)
        self.init(list: summary.with(covers: ListCovers.of(items)), items: items)
    }
}

/// **A row of the dish picker** — `my_scored_dishes`: one per (visit, dish), newest visit first.
///
/// Not ``ScoredDish`` (the You tab's per-review row, whose score is never absent): a picker row can be
/// unscored, and its key is the line, not a review.
public struct ListPickerDish: Sendable, Hashable, Identifiable, Decodable {
    public let entryID: UUID
    public let dishID: UUID
    public let dishName: String
    public let restaurantID: UUID?
    public let restaurantName: String?
    public let locality: String?
    public let score: Rating?
    public let photoURL: String?
    public let visitedAt: Date
    /// Already on the list the picker was opened for.
    public let inList: Bool

    // A wide row deserves a wide initialiser.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        entryID: UUID,
        dishID: UUID,
        dishName: String,
        restaurantID: UUID? = nil,
        restaurantName: String? = nil,
        locality: String? = nil,
        score: Rating? = nil,
        photoURL: String? = nil,
        visitedAt: Date,
        inList: Bool = false
    ) {
        self.entryID = entryID
        self.dishID = dishID
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.locality = locality
        self.score = score
        self.photoURL = photoURL
        self.visitedAt = visitedAt
        self.inList = inList
    }

    enum CodingKeys: String, CodingKey {
        case locality, score
        case entryID = "entry_id"
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case photoURL = "photo_url"
        case visitedAt = "visited_at"
        case inList = "in_list"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entryID: try container.decode(UUID.self, forKey: .entryID),
            dishID: try container.decode(UUID.self, forKey: .dishID),
            dishName: try container.decode(String.self, forKey: .dishName),
            restaurantID: try container.decodeIfPresent(UUID.self, forKey: .restaurantID),
            restaurantName: try container.decodeIfPresent(String.self, forKey: .restaurantName),
            locality: try container.decodeIfPresent(String.self, forKey: .locality),
            score: try container.decodeIfPresent(Rating.self, forKey: .score),
            photoURL: try container.decodeIfPresent(String.self, forKey: .photoURL),
            visitedAt: try container.decode(Date.self, forKey: .visitedAt),
            inList: try container.decodeIfPresent(Bool.self, forKey: .inList) ?? false
        )
    }

    public var line: DishLine { DishLine(entryID: entryID, dishID: dishID) }
    public var id: DishLine { line }
    public var cursor: ListPickerCursor { ListPickerCursor(visitedAt: visitedAt, entryID: entryID, dishID: dishID) }

    /// The item this row becomes once added — before the server has named it.
    func item(id: UUID, position: Int, addedAt: Date) -> ListItem {
        ListItem(
            id: id, position: position, entryID: entryID, dishID: dishID, dishName: dishName,
            restaurantID: restaurantID, restaurantName: restaurantName, locality: locality, score: score,
            photoURL: photoURL, visitedAt: visitedAt, addedAt: addedAt
        )
    }
}

/// The picker's keyset: `(visited_at, entry_id, dish_id)` DESC — all three from the last row, or none.
public struct ListPickerCursor: Sendable, Hashable {
    public let visitedAt: Date
    public let entryID: UUID
    public let dishID: UUID

    public init(visitedAt: Date, entryID: UUID, dishID: UUID) {
        self.visitedAt = visitedAt
        self.entryID = entryID
        self.dishID = dishID
    }
}

/// One page of the picker.
public struct ListPickerPage: Sendable {
    public let items: [ListPickerDish]
    public let nextCursor: ListPickerCursor?

    public init(items: [ListPickerDish], nextCursor: ListPickerCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// A short read is the last page.
    public init(items: [ListPickerDish], requestedLimit: Int) {
        self.init(items: items, nextCursor: items.count < requestedLimit ? nil : items.last?.cursor)
    }
}

/// One page of the shelf.
public struct UserListPage: Sendable {
    public let items: [UserList]
    public let nextCursor: PageCursor?

    public init(items: [UserList], nextCursor: PageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public init(items: [UserList], requestedLimit: Int) {
        self.init(items: items, nextCursor: items.count < requestedLimit ? nil : items.last?.cursor)
    }
}

/// **A list, as the "Add to a list" sheet sees it** — `my_lists_for_dish_line`. `itemID` non-nil means
/// this line is already on it, and is what unticking removes.
public struct ListMembership: Sendable, Hashable, Identifiable, Decodable {
    public let listID: UUID
    public let name: String
    public let itemCount: Int
    public let itemID: UUID?

    public init(listID: UUID, name: String, itemCount: Int, itemID: UUID?) {
        self.listID = listID
        self.name = name
        self.itemCount = max(0, itemCount)
        self.itemID = itemID
    }

    enum CodingKeys: String, CodingKey {
        case name
        case listID = "list_id"
        case itemCount = "item_count"
        case itemID = "item_id"
    }

    public var id: UUID { listID }
    public var contains: Bool { itemID != nil }

    func holding(_ itemID: UUID?) -> ListMembership {
        let delta = (itemID != nil ? 1 : 0) - (self.itemID != nil ? 1 : 0)
        return ListMembership(listID: listID, name: name, itemCount: itemCount + delta, itemID: itemID)
    }
}

/// What `add_list_item` answers: the item, appended last (or the existing one — it is idempotent).
public struct ListItemReceipt: Sendable, Hashable, Decodable {
    public let itemID: UUID
    public let listID: UUID
    public let entryID: UUID
    public let dishID: UUID
    public let position: Int
    public let addedAt: Date

    public init(itemID: UUID, listID: UUID, entryID: UUID, dishID: UUID, position: Int, addedAt: Date) {
        self.itemID = itemID
        self.listID = listID
        self.entryID = entryID
        self.dishID = dishID
        self.position = position
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case listID = "list_id"
        case entryID = "entry_id"
        case dishID = "dish_id"
        case position = "item_position"
        case addedAt = "added_at"
    }
}

/// The shelf's cover rule, shared by both implementations and by a list edited in place: up to four
/// distinct item photos, in list order.
enum ListCovers {
    static func of(_ items: [ListItem]) -> [String] {
        var seen = Set<String>()
        let photos = items.sorted { $0.position < $1.position }.compactMap(\.photoURL)
        return Array(photos.filter { seen.insert($0).inserted }.prefix(UserList.coverLimit))
    }
}
