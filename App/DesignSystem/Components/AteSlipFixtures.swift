import AteKit
import SwiftUI

/// **The design's own entry, as a fixture** — what previews, the debug gallery and a screenshot
/// drive draw, so what they show and what `design/v1` draws are the same words, dishes and scores.
///
/// `DEBUG || BETA` rather than `DEBUG`: the gallery these feed ships to TestFlight.
#if DEBUG || BETA
extension UUID {
    /// **The same seed is the same id every launch.** Letter tiles and avatars take their accent from
    /// the id's bytes, so a fixture minted fresh painted differently each time it was drawn, and the
    /// snapshot tests compared two different pictures of the same page.
    static func fixture(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (offset, byte) in seed.utf8.enumerated() {
            bytes[offset % 16] = bytes[offset % 16] &* 31 &+ byte &+ UInt8(truncatingIfNeeded: offset)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension AteSlip {
    private static func dish(_ name: String, score: Rating? = nil, isSaved: Bool = false) -> Dish {
        Dish(id: .fixture("slip.\(name)"), dishID: .fixture(name), name: name, score: score, isSaved: isSaved)
    }

    @MainActor
    static var previewJournal: AteSlip {
        AteSlip(
            dishes: [
                dish("Tagliatelle al ragù", score: Rating(rounding: 4.5)),
                dish("Tiramisu", score: Rating(rounding: 3)),
                dish("Prawn spaghetti")
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
                dish("Cheeseburger", score: Rating(rounding: 4.5), isSaved: true),
                dish("Fries", score: Rating(rounding: 4))
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

    /// `ComposerPlaceB`'s words: the place is on the key, and the last number is still being typed.
    static var previewComposerWords: EntryComposition {
        fixture(
            "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in "
                + "four minutes. Tiramisu a bit flat after that, 3",
            [.score(Rating(rounding: 4.5))]
        )
    }
}
#endif
