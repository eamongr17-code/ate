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

    // A dish wears each code once (Eamon, 7 Oct): the key takes a code it already wears back off.

    @Test("a second code joins the dish's chips; the same code again comes back off")
    func togglesTheDishsOwnCode() throws {
        let words = EntryComposition(plain: "the tiramisu", spans: [])
        let first = try #require(words.togglingTag(.gf, atDisplayOffset: 12))
        #expect(first.edit == .added(.gf))
        let second = try #require(first.composition.togglingTag(.v, atDisplayOffset: first.caret))
        #expect(second.edit == .added(.v))
        #expect(second.composition.plain == "the tiramisu GF V ")
        #expect(second.composition.dishTags(atDisplayOffset: second.caret) == [.gf, .v])

        let again = try #require(second.composition.togglingTag(.gf, atDisplayOffset: second.caret))
        #expect(again.edit == .removed(.gf))
        #expect(again.composition.plain == "the tiramisu V ", "the chip goes with one of its spaces")
        #expect(again.composition.tags == [.v])
        #expect(again.caret == again.composition.displayString.utf16.count, "the caret stays at the end")
    }

    @Test("pressed after the dish's score, the chip in front of the score comes off")
    func togglesBeforeAScore() throws {
        let words = EntryComposition(plain: "tiramisu GF 3.0 ", spans: [
            EntryTokenSpan(token: EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF"))),
                           span: TextSpan(location: 9, length: 2)),
            EntryTokenSpan(
                token: EntryToken(kind: .score(Rating(exactly: 3)!)), span: TextSpan(location: 12, length: 3)
            )
        ])
        let end = words.displayString.utf16.count
        #expect(words.dishTags(atDisplayOffset: end) == [.gf])
        let pressed = try #require(words.togglingTag(.gf, atDisplayOffset: end))
        #expect(pressed.edit == .removed(.gf))
        #expect(pressed.composition.plain == "tiramisu 3.0 ")
        #expect(pressed.composition.scores.map(\.value) == [3])
    }

    @Test("another dish's code is not this dish's: the same code goes on again")
    func anotherDishsCode() throws {
        let words = EntryComposition(plain: "salad GF and the pasta", spans: [
            EntryTokenSpan(token: EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF"))),
                           span: TextSpan(location: 6, length: 2))
        ])
        let end = words.displayString.utf16.count
        #expect(words.dishTags(atDisplayOffset: end).isEmpty)
        let pressed = try #require(words.togglingTag(.gf, atDisplayOffset: end))
        #expect(pressed.edit == .added(.gf))
        #expect(pressed.composition.tags == [.gf, .gf])
    }

    @Test("typing a code the dish already wears leaves it as words")
    func typedDuplicateStaysWords() {
        let gf = EntryTokenSpan(
            token: EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF"))), span: TextSpan(location: 6, length: 2)
        )
        let duplicate = EntryComposition(plain: "salad GF gf", spans: [gf])
        #expect(duplicate.pendingTagLiteral(atDisplayOffset: duplicate.displayString.utf16.count) == nil)
        let another = EntryComposition(plain: "salad GF vg", spans: [gf])
        let found = another.pendingTagLiteral(atDisplayOffset: another.displayString.utf16.count)
        #expect(found?.mark.tag == .vg)
    }
}
