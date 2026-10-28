import Foundation

/// **The nineteen plate awards** (0098, `design/rebuild/plate-awards*.html`), in the order the set is
/// drawn. Each is a plate from a world ceramic tradition, and every one is about the food, never a
/// place. The mockup's twentieth, the first drink, was retired before launch (0099: "just plates").
///
/// The raw value is the server's id; the live plate page and its stills use the same ids.
public enum PlateAward: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case dishes1 = "dishes_1"
    case dishes10 = "dishes_10"
    case dishes25 = "dishes_25"
    case dishes50 = "dishes_50"
    case dishes100 = "dishes_100"
    case dishes250 = "dishes_250"
    case dishes500 = "dishes_500"
    case first5 = "first_5"
    case first6 = "first_6"
    case firstHalf = "first_half"
    case firstDessert = "first_dessert"
    case newCountry = "new_country"
    case ateWith = "ate_with"
    case savedBySomeone = "saved_by_someone"
    case saves10 = "saves_10"
    case sameDish3 = "same_dish_3"
    case fiveInEntry = "five_in_entry"
    case threeInDay = "three_in_day"
    case fiveAtPlace = "five_at_place"

    public var id: String { rawValue }

    /// Its name, as the takeover, the grid and the backstamp print it. Headings say literally what
    /// they show.
    public var name: String {
        switch self {
        case .dishes1: "First dish"
        case .dishes10: "10 dishes"
        case .dishes25: "25 dishes"
        case .dishes50: "50 dishes"
        case .dishes100: "100 dishes"
        case .dishes250: "250 dishes"
        case .dishes500: "500 dishes"
        case .first5: "First 5.0"
        case .first6: "First 6"
        case .firstHalf: "First 0.5"
        case .firstDessert: "First dessert"
        case .newCountry: "Dish in a new country"
        case .ateWith: "Ate with someone"
        case .savedBySomeone: "Dish saved by someone"
        case .saves10: "10 saves"
        case .sameDish3: "Same dish 3 times"
        case .fiveInEntry: "5 dishes in one entry"
        case .threeInDay: "3 entries in one day"
        case .fiveAtPlace: "5 dishes at one place"
        }
    }

    /// The 6 is a secret: its plate does not appear, not even as a silhouette, until it is earned.
    public var isSecret: Bool { self == .first6 }

    /// The N of a dish count ("Your first N dishes"); nil for every other award. The first dish is
    /// an entry award — one dish is that dish.
    public var milestone: Int? {
        switch self {
        case .dishes10: 10
        case .dishes25: 25
        case .dishes50: 50
        case .dishes100: 100
        case .dishes250: 250
        case .dishes500: 500
        default: nil
        }
    }

    /// The dish counts, smallest first — what "Next award in N dishes" counts towards.
    public static let milestones: [Int] = [1, 10, 25, 50, 100, 250, 500]

    /// What an opened award shows (the approved detail, by type).
    public enum Opening: Sendable, Hashable {
        /// "Your first N dishes": the lines that got you there, oldest first, the Nth ringed.
        case mosaic(Int)
        /// A few dishes (`award_lines`): one entry's five, one place's five, the 10 saves' dishes,
        /// the same dish's three lines, the saved dish.
        case dishes
        /// The entries behind it, each as its slip (`get_entry_card`).
        case entries
    }

    public var opening: Opening {
        if let milestone { return .mosaic(milestone) }
        switch self {
        case .fiveInEntry, .fiveAtPlace, .saves10, .sameDish3, .savedBySomeone: return .dishes
        default: return .entries
        }
    }

    /// The still in the app bundle (`design/plates/bake.js`).
    public var stillName: String { "plate-\(rawValue)" }
}

extension PlateAward {
    /// How many more dishes until the next dish count, or nil past 500.
    public static func dishesToNext(after dishes: Int) -> Int? {
        milestones.first { $0 > dishes }.map { $0 - dishes }
    }
}
