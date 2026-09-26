#if DEBUG
import Foundation

/// The artboards' own feed, as data: three people, five visits, the same dishes, scores, suburbs
/// and saves `design/v1/Feed.dc.html` draws. Ages are computed from now, so a drive
/// photographed at any hour still reads "2h" and "5h" where the artboard does.
public extension InMemorySocialService {

    enum Seed {
        // Chosen so each person's avatar lands on the accent `Feed.dc.html` paints them in —
        // butter, green, lilac — since the colour is picked from the UUID (`AteAvatar.index`).
        public static let jess = UUID(uuidString: "11111111-0000-4000-8000-000000000003")!
        public static let marcus = UUID(uuidString: "11111111-0000-4000-8000-000000000004")!
        public static let priya = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!

        static let tipo = EntryCard.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
            name: "Tipo 00", address: "361 Little Bourke St", city: "Melbourne", locality: "CBD"
        )
        static let butchers = EntryCard.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000002")!,
            name: "Butchers Diner", address: "153 Bourke St", city: "Melbourne", locality: "CBD"
        )
        static let kisume = EntryCard.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000003")!,
            name: "Kisume", address: "175 Flinders Ln", city: "Melbourne", locality: "CBD"
        )
        static let beatrix = EntryCard.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000004")!,
            name: "Beatrix", address: "688 Queensberry St", city: "Melbourne",
            locality: "North Melbourne"
        )

        static func hoursAgo(_ hours: Double) -> Date {
            Date(timeIntervalSinceNow: -hours * 3600)
        }
    }

    static var seededProfiles: [ProfileSummary] {
        [
            ProfileSummary(userID: Seed.jess, username: "jessw", name: "Jess W", city: "Melbourne",
                           orders: 86, places: 40, dishes: 201, scored: 187, avgScore: 4.1),
            ProfileSummary(userID: Seed.marcus, username: "marcus.eats", name: "Marcus",
                           city: "Melbourne", orders: 34, places: 22, dishes: 71, scored: 64,
                           avgScore: 3.8),
            ProfileSummary(userID: Seed.priya, username: "priya", name: "Priya", city: "Melbourne",
                           orders: 12, places: 9, dishes: 29, scored: 29, avgScore: 4.4)
        ]
    }

    static var seededEntries: [EntryCard] {
        [
            entry(
                id: "E0000000-0000-4000-8000-000000000001",
                author: Seed.jess, username: "jessw", orderNumber: 86, place: Seed.tipo,
                body: "Birthday pasta. Still the best thing on Little Bourke, fight me.",
                createdAt: Seed.hoursAgo(2),
                photos: ["prawn", "tiramisu", "ragu"],
                // Three dishes: the feed leaves this visit's words to the entry (`SlipAnatomy`).
                items: [("Prawn spaghetti", 5.0), ("Tiramisu", 4.0), ("Tagliatelle al ragù", 4.5)]
            ),
            entry(
                id: "E0000000-0000-4000-8000-000000000002",
                author: Seed.marcus, username: "marcus.eats", orderNumber: 34, place: Seed.butchers,
                body: "Queued forty minutes for this and would queue again.",
                createdAt: Seed.hoursAgo(5),
                photos: ["burger"],
                items: [("Cheeseburger", 4.5)]
            ),
            entry(
                id: "E0000000-0000-4000-8000-000000000003",
                author: Seed.priya, username: "priya", orderNumber: 12, place: Seed.kisume,
                body: "Omakase night. The salmon roll was the quiet star.",
                createdAt: Seed.hoursAgo(26),
                photos: ["sushi", "ragu", "cake"],
                items: [("Salmon roll", 5.0), ("Wagyu nigiri", 4.5)]
            ),
            entry(
                id: "E0000000-0000-4000-8000-000000000004",
                author: Seed.jess, username: "jessw", orderNumber: 85, place: Seed.beatrix,
                body: "Raspberry cake for breakfast. No notes.",
                createdAt: Seed.hoursAgo(96),
                photos: ["cake"],
                items: [("Raspberry cake", 5.0)]
            ),
            // A visit the sorter could not score every line of — one dish, no number. The feed
            // leaves the score slot empty: no star, no text (design rule 7).
            entry(
                id: "E0000000-0000-4000-8000-000000000005",
                author: Seed.marcus, username: "marcus.eats", orderNumber: 33, place: Seed.tipo,
                body: "Back again. Ordered the penne this time.",
                createdAt: Seed.hoursAgo(120),
                photos: ["penne"],
                items: [("Penne alla vodka", nil)]
            )
        ]
    }

    /// `-ate-preview-long`: a visit by somebody with a very long handle — three dishes and not one
    /// photo, the slip that used to have no way into its entry — so the truncating byline and the
    /// paper's own tap can be driven on a simulator.
    static var longEntries: [EntryCard] {
        [
            entry(
                id: "E0000000-0000-4000-8000-0000000000A1",
                author: Seed.priya, username: "the.very.long.handle.of.someone.hungry",
                orderNumber: 13, place: Seed.kisume,
                body: "Three things, no photos, all good.",
                createdAt: Seed.hoursAgo(1),
                photos: [],
                items: [("Salmon roll", 4.5), ("Wagyu nigiri", 5.0), ("Miso soup", 3.5)]
            )
        ]
    }

    /// The two bookmarks `Feed.dc.html` draws filled: Jess's tiramisu and Marcus's cheeseburger.
    static var seededSaves: [UUID] {
        [
            derived(from: "E0000000-0000-4000-8000-000000000001", prefix: "D", index: 1),
            derived(from: "E0000000-0000-4000-8000-000000000002", prefix: "D", index: 0)
        ]
    }

    // A fixture builder is wide by nature; the alternative is five hand-written rows.
    // swiftlint:disable:next function_parameter_count
    private static func entry(
        id: String,
        author: UUID,
        username: String,
        orderNumber: Int,
        place: EntryCard.Place,
        body: String,
        createdAt: Date,
        photos: [String],
        items: [(String, Double?)]
    ) -> EntryCard {
        let entryID = UUID(uuidString: id)!
        return EntryCard(
            id: entryID,
            authorID: author,
            body: body,
            visibility: .public,
            restaurantID: place.id,
            restaurantSource: "sorter",
            orderNumber: orderNumber,
            sortStatus: .sorted,
            sortedAt: createdAt,
            createdAt: createdAt,
            isMine: false,
            author: EntryCard.Author(id: author, username: username, city: "Melbourne"),
            place: place,
            photos: photos.enumerated().map { EntryCard.Photo(url: "asset://\($1)", position: $0 + 1) },
            items: items.enumerated().map { index, item in
                EntryCard.Item(
                    reviewID: derived(from: id, prefix: "C", index: index),
                    dishID: derived(from: id, prefix: "D", index: index),
                    dishName: item.0,
                    score: item.1.map { Rating(rounding: $0) },
                    position: index + 1
                )
            }
        )
    }

    /// A line's ids, derived from its entry's so the same fixture always mints the same dish — a
    /// preview whose ids move between launches cannot have a save state at all.
    private static func derived(from entryID: String, prefix: String, index: Int) -> UUID {
        let head = prefix + String(format: "%07X", index + 1)
        return UUID(uuidString: head + entryID.dropFirst(8)) ?? UUID()
    }
}
#endif
