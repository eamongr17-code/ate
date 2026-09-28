import Foundation
import Testing
@testable import AteKit

@Suite("The Diet key")
struct DietKeyTests {
    @Test("at the caret after a dish, the chip goes in with its spaces")
    func afterDish() throws {
        let words = EntryComposition(plain: "the tiramisu", spans: [])
        let (next, caret) = try #require(words.insertingTag(.gf, atDisplayOffset: 12))
        #expect(next.plain == "the tiramisu GF ")
        #expect(next.tags == [.gf])
        #expect(caret == next.displayString.utf16.count)
    }

    @Test("straight after a score, the chip goes between the dish and its score")
    func beforeScore() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 3)!)), span: TextSpan(location: 9, length: 3)
        )
        let words = EntryComposition(plain: "tiramisu 3.0 ", spans: [score])
        let end = words.displayString.utf16.count
        let (next, caret) = try #require(words.insertingTag(.v, atDisplayOffset: end))
        #expect(next.plain == "tiramisu V 3.0 ")
        #expect(next.tagTokens == [TagToken(offset: 9, length: 1)])
        #expect(caret == next.displayString.utf16.count)
    }

    // The four cases the rule is about: a chip belongs to the nearest dish on its LEFT, and goes out
    // as a `tag_token` where it sits — the sorter attaches it to the dish named nearest before it.

    @Test("chip right after a dish: at the caret, sent where it sits")
    func chipRightAfterADish() throws {
        let words = EntryComposition(plain: "The salmon roll", spans: [])
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: 15))
        #expect(next.plain == "The salmon roll GF ")
        #expect(next.tagTokens == [TagToken(offset: 16, length: 2)])
    }

    @Test("chip after a dish and its score: between the two, so it follows the dish")
    func chipAfterADishAndItsScore() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(location: 16, length: 3)
        )
        let words = EntryComposition(plain: "The salmon roll 4.5", spans: [score])
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: words.displayString.utf16.count))
        #expect(next.plain == "The salmon roll GF 4.5")
        #expect(next.tagTokens == [TagToken(offset: 16, length: 2)])
        #expect(next.scores.map(\.value) == [4.5], "the score is untouched")
    }

    @Test("chip several words later: where the person put it, still the dish before it")
    func chipSeveralWordsLater() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(location: 16, length: 3)
        )
        let words = EntryComposition(plain: "The salmon roll 4.5 was great, ", spans: [score])
        let end = words.displayString.utf16.count
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: end))
        #expect(next.plain == "The salmon roll 4.5 was great, GF ")
        #expect(next.tagTokens == [TagToken(offset: 31, length: 2)])
    }

    @Test("chip with no dish before it: the key inserts nothing")
    func chipWithNoDishBeforeIt() {
        #expect(EntryComposition(plain: "", spans: []).insertingTag(.gf, atDisplayOffset: 0) == nil)
        let small = EntryComposition(plain: "With my ", spans: [])
        #expect(small.insertingTag(.vg, atDisplayOffset: 8) == nil, "small words are never a dish")
        // …and it is what is to the LEFT that counts: a dish after the caret does not help.
        let later = EntryComposition(plain: "and the tiramisu", spans: [])
        #expect(later.insertingTag(.v, atDisplayOffset: 8) == nil)
        #expect(later.insertingTag(.v, atDisplayOffset: 16) != nil)
    }
}
