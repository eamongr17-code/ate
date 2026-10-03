#if DEBUG || BETA
import AteKit
import SwiftUI

/// The gallery's dishes, photos and slips — the mockups' own names and scores, the bundled food
/// photos, and fixed tile accents so the gallery paints the same way every launch.
@MainActor
enum KitFixtures {
    static let longName = "Hand-cut pappardelle with slow-braised duck ragù and aged pecorino"
    static let longPlace = "Osteria Ilaria at the Old Melbourne Post Office"

    static func dish(_ name: String, _ image: Image? = nil, accent: Int = 0) -> AtePhoto {
        AtePhoto(image: image, dish: DishLetter(dishID: UUID(), name: name, paletteIndex: accent))
    }

    static var ragu: AtePhoto { dish("Tagliatelle al ragù", Image(.Photos.ragu)) }
    static var prawn: AtePhoto { dish("Prawn dumplings", Image(.Photos.prawn)) }
    static var burger: AtePhoto { dish("Cheeseburger", Image(.Photos.burger)) }
    static var tiramisu: AtePhoto { dish("Tiramisu", Image(.Photos.tiramisu)) }
    static var sushi: AtePhoto { dish("Salmon roll", Image(.Photos.sushi)) }
    static var pizza: AtePhoto { dish("Margherita", Image(.Photos.pizza)) }
    static var penne: AtePhoto { dish("Penne alla vodka", Image(.Photos.penne)) }
    static var cake: AtePhoto { dish("Burnt basque cheesecake", Image(.Photos.cake)) }

    /// Letter tiles, each on its own accent (coral, green, pink, sky, lilac).
    static var pho: AtePhoto { dish("Pho tai", accent: 3) }
    static var souvlaki: AtePhoto { dish("Lamb souvlaki", accent: 4) }
    static var croissant: AtePhoto { dish("Pistachio croissant", accent: 1) }
    static var focaccia: AtePhoto { dish("Focaccia", accent: 0) }
    static var gnocchi: AtePhoto { dish("Gnocchi al ragù bianco", accent: 2) }

    static var photos: [AtePhoto] { [ragu, prawn, tiramisu] }

    static let four = AteScore.personal(Rating(rounding: 4.5))
    static let five = AteScore.personal(.perfect)
    static let six = AteScore.personal(.blownAway)

    static func slipDish(_ name: String, _ score: Double?, saved: Bool = false, tags: [DietTag] = []) -> AteSlip.Dish {
        AteSlip.Dish(
            id: UUID(), dishID: UUID(), name: name, score: score.map { Rating(exactly: $0) ?? Rating(rounding: $0) },
            isSaved: saved, tags: tags
        )
    }

    static let jess = AteByline(
        userID: UUID(uuidString: "6A0F1D2E-3B4C-4D5E-8F70-112233445566")!, handle: "jessw", age: "2h"
    )

    /// A feed visit of three dishes: its words are hidden in the feed.
    static var feedThree: AteSlip {
        AteSlip(
            dishes: [
                slipDish("Prawn spaghetti", 5),
                slipDish("Tiramisu", 4, saved: true, tags: [.v]),
                slipDish("Tagliatelle al ragù", 4.5, saved: true)
            ],
            place: "Tipo 00",
            suburb: "CBD",
            words: .previewWords,
            photos: [prawn, tiramisu, ragu],
            byline: jess
        )
    }

    /// Long names, long place, no photos, one unscored dish.
    static var long: AteSlip {
        AteSlip(
            dishes: [slipDish(longName, 6), slipDish("Grilled sourdough", nil, tags: [.vg, .df])],
            place: longPlace,
            suburb: "Collingwood North",
            meta: .age("3d"),
            words: .previewFeedWords
        )
    }

    /// The design's own visits, with the bundled photos in place of flat swatches.
    static var journal: AteSlip {
        var slip = AteSlip.previewJournal
        slip.photos = photos
        return slip
    }

    static var feed: AteSlip {
        var slip = AteSlip.previewFeed
        slip.photos = [burger]
        return slip
    }

    static var placeVisit: AteSlip {
        var slip = journal
        slip.byline = AteByline(userID: jess.userID, handle: "eamon", age: "Sat 19 Sep", isYou: true)
        return slip
    }
}
#endif
