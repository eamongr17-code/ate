import Foundation
import Testing
@testable import AteKit

/// A journal slip heads with the place, so the pill comes off the front of the words —
/// `Main.dc.html` starts its prose at "With Jess for her birthday."
@Suite("Dropping a leading place")
struct LeadingPlaceTests {
    private func composition(_ text: String, place: String?, scoreAt: String? = nil) -> EntryComposition {
        var spans: [EntryTokenSpan] = []
        if let place, let range = text.range(of: place) {
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: .place(PlaceRef(id: UUID(), name: place))),
                span: TextSpan(location: text.utf16.distance(from: text.utf16.startIndex,
                                                             to: range.lowerBound.samePosition(in: text.utf16)!),
                               length: place.utf16.count)
            ))
        }
        if let scoreAt, let range = text.range(of: scoreAt) {
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: .score(Rating(rounding: Double(scoreAt) ?? 4.5))),
                span: TextSpan(location: text.utf16.distance(from: text.utf16.startIndex,
                                                             to: range.lowerBound.samePosition(in: text.utf16)!),
                               length: scoreAt.utf16.count)
            ))
        }
        return EntryComposition(plain: text, spans: spans)
    }

    @Test("A place at the very start comes off, with its space")
    func dropsLeading() {
        let words = composition("Tipo 00 with Jess for her birthday.", place: "Tipo 00")
        let slip = words.droppingLeadingPlace()
        #expect(slip.plain == "With Jess for her birthday.")
        #expect(slip.place == nil)
    }

    @Test("The score tokens that follow keep their words")
    func keepsLaterTokens() {
        let words = composition("Tipo 00 with the ragù 4.5 after work.", place: "Tipo 00", scoreAt: "4.5")
        let slip = words.droppingLeadingPlace()
        #expect(slip.plain == "With the ragù 4.5 after work.")
        #expect(slip.scores.map(\.value) == [4.5])
        // The span still covers the score's own characters, which is what the model demands.
        #expect(slip.spans.count == 1)
    }

    @Test("A place named mid-sentence stays put")
    func keepsMidSentencePlace() {
        let words = composition("Dinner at Tipo 00 with Jess.", place: "Tipo 00")
        #expect(words.droppingLeadingPlace() == words)
    }

    @Test("Words with no place are untouched")
    func keepsPlainWords() {
        let words = composition("Just a sandwich.", place: nil)
        #expect(words.droppingLeadingPlace() == words)
    }
}
