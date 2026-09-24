import Foundation

/// **The monthly statement** — `monthly_statement(p_user_id, p_month, p_tz)`, one jsonb object.
///
/// Nine figures and three little lists, and the three lists are why the bands below them are
/// *conditional*: a month where nothing was scored has no "Top of the month" to print, and design
/// rule 4 says a receipt only prints what was actually printed. Absent is absent — never a zero row.
public struct MonthlyStatement: Sendable, Hashable, Codable {

    /// A line of "Top of the month": the dish, where it was, and what you gave it.
    public struct TopDish: Sendable, Hashable, Codable, Identifiable {
        public let dishID: UUID
        public let dishName: String
        public let restaurantName: String?
        /// Always present in practice — the RPC only ranks scored lines — but nullable on the wire.
        public let score: Double?

        public var id: UUID { dishID }

        public init(dishID: UUID, dishName: String, restaurantName: String? = nil, score: Double? = nil) {
            self.dishID = dishID
            self.dishName = dishName
            self.restaurantName = restaurantName
            self.score = score
        }

        enum CodingKeys: String, CodingKey {
            case score
            case dishID = "dish_id"
            case dishName = "dish_name"
            case restaurantName = "restaurant_name"
        }
    }

    /// "Most ordered … Pasta x4".
    public struct DishTally: Sendable, Hashable, Codable {
        public let dishName: String
        public let count: Int

        public init(dishName: String, count: Int) {
            self.dishName = dishName
            self.count = count
        }

        enum CodingKeys: String, CodingKey {
            case count
            case dishName = "dish_name"
        }
    }

    /// "Regular at … Tipo 00 x2".
    public struct PlaceTally: Sendable, Hashable, Codable {
        public let restaurantID: UUID?
        public let restaurantName: String
        public let count: Int

        public init(restaurantID: UUID? = nil, restaurantName: String, count: Int) {
            self.restaurantID = restaurantID
            self.restaurantName = restaurantName
            self.count = count
        }

        enum CodingKeys: String, CodingKey {
            case count
            case restaurantID = "restaurant_id"
            case restaurantName = "restaurant_name"
        }
    }

    public let month: StatementMonth
    /// Whose statement it is. A receipt is signed, and it is signed from the same payload that
    /// printed it — never from a second call that could answer for somebody else.
    public let username: String?
    /// Entries written this month.
    public let orders: Int
    public let places: Int
    /// Places visited this month that had never been visited before it.
    public let newPlaces: Int
    /// Receipt line items — the north-star unit (PRODUCT.md).
    public let dishes: Int
    /// The sum of the scores handed out. A half-step sum, so it can land on `.5`.
    public let stars: Double
    /// Over SCORED lines only — an unscored dish never drags an average down (design rule 7).
    /// `nil` for a month where nothing was scored, which prints as the em-dash, never as `0.0`.
    public let average: Double?
    /// Up to three.
    public let topDishes: [TopDish]
    public let mostOrdered: DishTally?
    public let mostVisited: PlaceTally?

    public init(
        month: StatementMonth,
        username: String? = nil,
        orders: Int = 0,
        places: Int = 0,
        newPlaces: Int = 0,
        dishes: Int = 0,
        stars: Double = 0,
        average: Double? = nil,
        topDishes: [TopDish] = [],
        mostOrdered: DishTally? = nil,
        mostVisited: PlaceTally? = nil
    ) {
        self.month = month
        self.username = username
        self.orders = orders
        self.places = places
        self.newPlaces = newPlaces
        self.dishes = dishes
        self.stars = stars
        self.average = average
        self.topDishes = topDishes
        self.mostOrdered = mostOrdered
        self.mostVisited = mostVisited
    }

    enum CodingKeys: String, CodingKey {
        case month, username, orders, places, dishes, stars, average
        case newPlaces = "new_places"
        case topDishes = "top_dishes"
        case mostOrdered = "most_ordered"
        case mostVisited = "most_visited"
    }

    /// Every key is documented as always present, but a statement is a page we would rather draw
    /// short than not at all: each count decodes defensively so one added-later key cannot blank the
    /// screen. `average` stays genuinely optional — a missing average and a zero one are different
    /// facts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decode(StatementMonth.self, forKey: .month)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        orders = try container.decodeIfPresent(Int.self, forKey: .orders) ?? 0
        places = try container.decodeIfPresent(Int.self, forKey: .places) ?? 0
        newPlaces = try container.decodeIfPresent(Int.self, forKey: .newPlaces) ?? 0
        dishes = try container.decodeIfPresent(Int.self, forKey: .dishes) ?? 0
        stars = try container.decodeIfPresent(Double.self, forKey: .stars) ?? 0
        average = try container.decodeIfPresent(Double.self, forKey: .average)
        topDishes = try container.decodeIfPresent([TopDish].self, forKey: .topDishes) ?? []
        mostOrdered = try container.decodeIfPresent(DishTally.self, forKey: .mostOrdered)
        mostVisited = try container.decodeIfPresent(PlaceTally.self, forKey: .mostVisited)
    }
}
