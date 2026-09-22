import Foundation
import Testing
@testable import AteKit

@Suite("Entry body tokens — finding the scores in the words")
struct EntryBodyTokensTests {

    private func card(_ body: String, place: String? = "Tipo 00", items: [(String, Double?)]) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: UUID(),
            body: body,
            orderNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            place: place.map { EntryCard.Place(id: UUID(), name: $0) },
            items: items.enumerated().map { offset, item in
                EntryCard.Item(
                    reviewID: UUID(), dishID: UUID(), dishName: item.0,
                    score: item.1.flatMap { Rating(exactly: $0) }, position: offset + 1
                )
            }
        )
    }

    private func slice(_ span: TextSpan, of text: String) -> String {
        let units = Array(text.utf16)
        return String(decoding: units[span.location..<span.endLocation], as: UTF16.self)
    }

    @Test("a score inside a price is not the score")
    func priceIsNotAScore() {
        let body = "Paid $14.50 for the pasta and it was worth it, a clear 4.5 out of 5."
        let composition = EntryBodyTokens.composition(for: card(body, place: nil, items: [("pasta", 4.5)]))

        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        #expect(slice(span, of: body) == "4.5")
        // Not the "4.5" inside "$14.50" — the pill must sit on the score they actually gave.
        #expect(span.location > body.distance(from: body.startIndex, to: body.range(of: "pasta")!.lowerBound))
    }

    @Test("digits either side disqualify an occurrence", arguments: [
        "Table 14.55 and the ragù 4.5 after",
        "It cost 4.50 and the ragù 4.5 after",
        "Bill was 24.5, the ragù 4.5 after"
    ])
    func boundaries(body: String) {
        let composition = EntryBodyTokens.composition(for: card(body, place: nil, items: [("ragù", 4.5)]))
        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        let before = span.location > 0 ? Array(body.utf16)[span.location - 1] : 32
        #expect(before == 32, "the surviving occurrence is the one after a space")
    }

    @Test("with several honest occurrences, the one nearest the dish wins")
    func nearestTheDish() {
        let body = "The tiramisu 4.0 was fine. The tagliatelle al ragù 4.5 was unreal. Tiramisu 4.0 again."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [("Tagliatelle al ragù", 4.5), ("Tiramisu", 4.0)]
        ))

        #expect(composition.spans.count == 2)
        // The 4.0 chosen is the FIRST one, next to the first "tiramisu" — not the trailing repeat.
        let scores = composition.spans.compactMap(\.token.score?.value)
        #expect(scores.sorted() == [4.0, 4.5])
        let fourOh = composition.spans.first { $0.token.score?.value == 4.0 }!
        #expect(fourOh.span.location < 20, "the 4.0 beside the first tiramisu, not the one at the end")
    }

    @Test("two items with the same score take different occurrences")
    func sameScoreTwice() {
        let body = "Pork bun 4.0 and the prawn dumpling 4.0, both excellent."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [("Pork bun", 4.0), ("Prawn dumpling", 4.0)]
        ))
        #expect(composition.spans.count == 2)
        #expect(composition.spans[0].span.location != composition.spans[1].span.location)
    }

    @Test("the place token is found, and a dish named in different case still matches")
    func placeAndCaseInsensitiveDish() {
        let body = "Tipo 00 with Jess. The salmon roll 4.5 was the quiet star."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: "Tipo 00", items: [("Salmon roll", 4.5)]
        ))
        #expect(composition.place?.name == "Tipo 00")
        #expect(composition.scores.map(\.value) == [4.5])
    }

    @Test("an unscored line contributes no pill, and a score absent from the words is dropped")
    func nothingIsInvented() {
        let body = "The prawn spaghetti looked the business."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [("Prawn spaghetti", nil), ("Tiramisu", 3.0)]
        ))
        #expect(composition.spans.isEmpty, "no number in the words means no pill in the words")
        #expect(composition.plain == body, "and the words are untouched either way")
    }
}
