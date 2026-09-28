#if DEBUG
import Foundation

public extension EntryCard {
    /// The `journal` fixture (``DebugLaunch/Fixture/journal``): a longer journal for the round 4
    /// filter and sort drives — a dozen visits over four months and two years, at six places, scored
    /// and unscored, with dietary tags, so every filter has something to find and every month marker
    /// something to say. In-memory only; never on a server.
    static var previewJournalIfRequested: [EntryCard] {
        DebugLaunch.has(.journal) ? previewJournalExtras : []
    }

    private static func previewID(_ prefix: String, _ tail: String) -> UUID {
        UUID(uuidString: "\(prefix)-0000-4000-8000-\(tail)")!
    }

    private struct PreviewVisit {
        let daysBack: Double
        let place: Int
        let dishes: [PreviewDish]
        let photos: [String]
        let words: String

        init(_ daysBack: Double, _ place: Int, _ dishes: [PreviewDish], _ photos: [String], _ words: String) {
            self.daysBack = daysBack
            self.place = place
            self.dishes = dishes
            self.photos = photos
            self.words = words
        }
    }

    private struct PreviewDish {
        let name: String
        let score: Double?
        let tags: [DietTag]

        init(_ name: String, _ score: Double?, _ tags: [DietTag]) {
            self.name = name
            self.score = score
            self.tags = tags
        }
    }

    static var previewJournalExtras: [EntryCard] {
        let places = [
            Place(id: previewID("B7E00000", "0000000000A1"), name: "Supernormal", locality: "CBD"),
            Place(id: previewID("B7E00000", "0000000000A2"), name: "Shira Nui", locality: "Glen Waverley"),
            Place(id: previewID("B7E00000", "0000000000A3"), name: "Leonardo's Pizza Palace", locality: "Carlton"),
            Place(id: previewID("B7E00000", "0000000000A4"), name: "Rockwell & Sons", locality: "Collingwood"),
            Place(id: previewID("B7E00000", "000000000001"), name: "Tipo 00", locality: "CBD"),
            Place(id: previewID("B7E00000", "0000000000A5"), name: "Neat maiden", locality: "CBD")
        ]
        typealias Dish = PreviewDish
        let visits: [PreviewVisit] = [
            PreviewVisit(4, 0, [Dish("Lobster roll", 4.5, []), Dish("Peanut butter parfait", 5, [.v])],
                         ["burger", "cake"],
             "The lobster roll is still the thing. Parfait to finish, as always."),
            PreviewVisit(11, 1, [Dish("Omakase", 5, [.gf]), Dish("Tamago", 3.5, [])], ["sushi"],
             "Twenty pieces and not one wrong. The tamago was the only soft note."),
            PreviewVisit(23, 2, [Dish("Margherita", 4, [.v]), Dish("Penne vodka", nil, [])], ["pizza", "penne"],
             "Loud room, good pizza. Forgot to score the penne, it was fine."),
            PreviewVisit(37, 3, [Dish("Double cheeseburger", 4.5, []), Dish("Fried chicken sandwich", 3, [])],
                         ["burger"],
             "The double is the move. Chicken was dry."),
            PreviewVisit(52, 4, [Dish("Tagliatelle al ragù", 5, []), Dish("Tiramisu", 4, [.v])], ["ragu", "tiramisu"],
             "Second time this year. Still the best ragù in town."),
            PreviewVisit(68, 0, [Dish("Duck bao", 4, [.df])], [],
             "Just the bao at the bar, in and out."),
            PreviewVisit(96, 2, [Dish("Pepperoni", 3.5, [])], ["pizza"],
             "Pepperoni was a little greasy tonight."),
            PreviewVisit(131, 1, [Dish("Salmon nigiri", 4.5, [.gf, .df])], ["sushi"],
             "Lunch set. Nigiri was perfect."),
            PreviewVisit(290, 3, [Dish("Mac and cheese", 3, [.v])], [],
             "Too rich by half."),
            PreviewVisit(402, 4, [Dish("Prawn spaghetti", 4.5, [.gf])], ["prawn"],
             "A year ago now. Prawn spaghetti the best of it."),
            // `MinimalEntry`: one dish and no other words — the slip says it once, in its row.
            PreviewVisit(2, 5, [Dish("Apple pie", 3.5, [.v])], [], "Apple pie V 3.5"),
            // A secret 6, so the calendar has a brick day.
            PreviewVisit(9, 1, [Dish("Chawanmushi", 6, [])], ["sushi"], "Chawanmushi I would cross town for.")
        ]
        let base = Date(timeIntervalSince1970: 1_789_812_840)
        let author = previewID("5C4B0D0E", "000000000001")
        return visits.enumerated().map { number, visit in
            let id = previewID("A7E00000", String(format: "0000000002%02d", number))
            let place = places[visit.place]
            return EntryCard(
                id: id,
                authorID: author,
                body: visit.words,
                restaurantID: place.id,
                restaurantSource: "user",
                orderNumber: 120 - number,
                sortStatus: .sorted,
                createdAt: base.addingTimeInterval(-visit.daysBack * 86_400),
                author: Author(id: author, username: "eamon"),
                place: place,
                photos: visit.photos.enumerated().map { Photo(url: "asset://\($1)", position: $0 + 1) },
                items: visit.dishes.enumerated().map { position, dish in
                    let tail = String(format: "00000002%02d%02d", number, position)
                    return Item(
                        reviewID: previewID("C7E00000", tail),
                        dishID: previewID("D7E00000", tail),
                        dishName: dish.name,
                        score: dish.score.map { Rating(exactly: $0) ?? Rating(rounding: $0) },
                        position: position + 1,
                        tags: dish.tags
                    )
                }
            )
        }
    }
}
#endif
