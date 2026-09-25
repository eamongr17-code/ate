import AteKit
import SwiftUI

/// **The design's own entry, as a fixture** — what previews, the debug gallery and a screenshot
/// drive draw, so what they show and what `design/v1` draws are the same words, dishes and scores.
///
/// `DEBUG || BETA` rather than `DEBUG`: the gallery these feed ships to TestFlight.
#if DEBUG || BETA
extension AteSlip {
    @MainActor
    static var previewJournal: AteSlip {
        AteSlip(
            dishes: [
                Dish(id: UUID(), dishID: UUID(), name: "Tagliatelle al ragù", score: Rating(rounding: 4.5)),
                Dish(id: UUID(), dishID: UUID(), name: "Tiramisu", score: Rating(rounding: 3)),
                Dish(id: UUID(), dishID: UUID(), name: "Prawn spaghetti")
            ],
            place: "Tipo 00",
            suburb: "CBD",
            meta: .day("Sat 19 Sep"),
            words: .previewWords,
            photos: AtePhoto.swatches
        )
    }

    @MainActor
    static var previewFeed: AteSlip {
        AteSlip(
            dishes: [
                Dish(id: UUID(), dishID: UUID(), name: "Cheeseburger",
                     score: Rating(rounding: 4.5), isSaved: true),
                Dish(id: UUID(), dishID: UUID(), name: "Fries", score: Rating(rounding: 4))
            ],
            place: "Butchers Diner",
            suburb: "CBD",
            words: .previewFeedWords,
            photos: [AtePhoto.swatch(AteColor.coral)],
            byline: AteByline(userID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                              handle: "marcus.eats", age: "5h")
        )
    }
}

extension EntryComposition {
    /// Builds a fixture by *finding* each token's words in the sentence rather than hand-counting
    /// offsets — a fixture with a wrong offset is refused by the model and would silently show no
    /// tokens at all.
    static func fixture(_ text: String, _ kinds: [EntryTokenKind]) -> EntryComposition {
        var spans: [EntryTokenSpan] = []
        var searchStart = text.startIndex
        for kind in kinds {
            guard let range = text.range(of: kind.plainText, range: searchStart..<text.endIndex),
                  let lower = range.lowerBound.samePosition(in: text.utf16) else { continue }
            let location = text.utf16.distance(from: text.utf16.startIndex, to: lower)
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: kind),
                span: TextSpan(location: location, length: kind.plainText.utf16.count)
            ))
            searchStart = range.upperBound
        }
        return EntryComposition(plain: text, spans: spans)
    }

    /// The prototype's own sentence, tokens and all.
    static var previewWords: EntryComposition {
        fixture(
            "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, "
                + "gone in four minutes. Tiramisu 3.0 a bit flat after that.",
            [.score(Rating(rounding: 4.5)), .score(Rating(rounding: 3))]
        )
    }

    static var previewFeedWords: EntryComposition {
        fixture(
            "Queued forty minutes for this cheeseburger 4.5 and would queue again.",
            [.score(Rating(rounding: 4.5))]
        )
    }

    /// With a place token leading the sentence, as the composer and entry page show it.
    static var previewWordsWithPlace: EntryComposition {
        fixture(
            "Tipo 00 with Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, "
                + "glossy, gone in four minutes. Tiramisu 3.0 a bit flat after that.",
            [.place(PlaceRef(id: UUID(), name: "Tipo 00")), .score(Rating(rounding: 4.5)),
             .score(Rating(rounding: 3))]
        )
    }
}
#endif
