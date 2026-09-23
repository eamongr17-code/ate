import Foundation
import Testing

@testable import AteKit

@Suite("Score literal — moving on")
struct ScoreLiteralMoveOnTests {

    @Test("a decimal point typed after a digit is not moving on — it is the middle of 4.5")
    func decimalPointIsNotMovingOn() {
        #expect(ScoreLiteral.isMoveOn(".", afterDigit: true) == false)
        // The same character after a letter is a full stop, and always was.
        #expect(ScoreLiteral.isMoveOn(".", afterDigit: false))
    }

    @Test("everything else still means moved on, digit before it or not")
    func otherCharactersStillMoveOn() {
        for character in [" ", ",", "!", "?", ";", ":", "\n"] {
            #expect(ScoreLiteral.isMoveOn(character, afterDigit: true), "\(character) should move on")
            #expect(ScoreLiteral.isMoveOn(character, afterDigit: false), "\(character) should move on")
        }
    }

    @Test("typing 4.5 then a space promotes the whole number, not the 4 in front of the dot")
    func typingAHalfStepPromotesOnce() {
        // What the editor sees, in order: "…ragù 4", then ".", then "5", then " ".
        // At the dot it must NOT promote — that is the bug the composer drive caught, where the
        // words ended up holding a 4.0 token followed by a stray ".5".
        #expect(ScoreLiteral.isMoveOn(".", afterDigit: true) == false)

        // At the space it does, and what it finds is the whole 4.5.
        let words = "The tagliatelle al ragù 4.5 "
        let found = ScoreLiteral.candidate(in: words, caretUTF16: words.utf16.count - 1)
        #expect(found?.rating.value == 4.5)
        #expect(found?.span.length == 3)
    }
}

@Suite("Pending score literal — the guard against promoting a token twice")
struct PendingScoreLiteralTests {

    @Test("a number the person typed is pending")
    func typedNumberIsPending() {
        let words = EntryComposition(plain: "The tiramisu 3.0 ", spans: [])
        let found = words.pendingScoreLiteral(atDisplayOffset: words.plain.utf16.count - 1)
        #expect(found?.rating.value == 3.0)
    }

    @Test("a number that IS a token is not pending — Score key, slide, Done is one score")
    func tokenIsNotPending() {
        // What the Score key leaves behind: "tiramisu <4.5> ", caret after the pill.
        let token = EntryToken(kind: .score(Rating(rounding: 4.5)))
        let (words, caret) = EntryComposition(plain: "The tiramisu", spans: [])
            .inserting(token, atDisplayOffset: 12)

        #expect(words.spans.count == 1)
        // Done runs the same promotion the editor does. It must find nothing.
        #expect(words.pendingScoreLiteral(atDisplayOffset: caret) == nil)
        // …and one character further on, where a trailing space puts the caret.
        #expect(words.pendingScoreLiteral(atDisplayOffset: caret + 1) == nil)
    }

    @Test("a real number typed after an existing token is still found")
    func typingAfterATokenStillWorks() {
        let token = EntryToken(kind: .score(Rating(rounding: 4.5)))
        let (withToken, _) = EntryComposition(plain: "The ragù", spans: [])
            .inserting(token, atDisplayOffset: 8)
        let typed = withToken.applyingPlainEdit(
            replacing: TextSpan(location: withToken.plain.utf16.count, length: 0),
            with: "then the tiramisu 3.0 "
        )

        let found = typed.pendingScoreLiteral(atDisplayOffset: typed.displayString.utf16.count - 1)
        #expect(found?.rating.value == 3.0)
    }
}

@Suite("Entry composition — inline tokens in editable text")
struct EntryCompositionTests {

    // MARK: - Fixtures

    /// "Tipo 00 with Jess. The tagliatelle al ragù 4.5 was unreal."
    private static func sample() -> EntryComposition {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "Tipo 00 with Jess. The tagliatelle al ragù 4.5 was unreal."
        )
        let place = EntryToken(kind: .place(PlaceRef(id: UUID(), name: "Tipo 00")))
        let score = EntryToken(kind: .score(Rating(rounding: 4.5)))
        return EntryComposition(plain: composition.plain, spans: [
            EntryTokenSpan(token: place, span: TextSpan(location: 0, length: 7)),
            EntryTokenSpan(token: score, span: TextSpan(location: 43, length: 3))
        ])
    }

    // MARK: - Round trip

    @Test("the words are kept verbatim and the tokens are structure alongside them")
    func roundTrip() {
        let composition = Self.sample()
        #expect(composition.plain == "Tipo 00 with Jess. The tagliatelle al ragù 4.5 was unreal.")
        #expect(composition.spans.count == 2)
        #expect(composition.place?.name == "Tipo 00")
        #expect(composition.scores.map(\.value) == [4.5])
    }

    @Test("a span that does not cover its token's text is refused, never silently kept")
    func invariant() {
        let token = EntryToken(kind: .score(Rating(rounding: 4.5)))
        let composition = EntryComposition(
            plain: "gone in four minutes",
            spans: [EntryTokenSpan(token: token, span: TextSpan(location: 0, length: 3))]
        )
        #expect(composition.spans.isEmpty)
    }

    @Test("codable round trip survives, so a draft can be saved mid-sentence")
    func codable() throws {
        let composition = Self.sample()
        let data = try JSONEncoder().encode(composition)
        let decoded = try JSONDecoder().decode(EntryComposition.self, from: data)
        #expect(decoded == composition)
    }

    // MARK: - Display collapse

    @Test("each token collapses to exactly one display character")
    func displayString() {
        let composition = Self.sample()
        let display = composition.displayString
        #expect(display == "\u{FFFC} with Jess. The tagliatelle al ragù \u{FFFC} was unreal.")
        #expect(composition.displaySpans.allSatisfy { $0.span.length == 1 })
        #expect(composition.displaySpans.map(\.span.location) == [0, 37])
    }

    @Test("a tap anywhere on a token's placeholder finds that token")
    func tokenLookup() {
        let composition = Self.sample()
        #expect(composition.token(atDisplayOffset: 0)?.place?.name == "Tipo 00")
        #expect(composition.token(atDisplayOffset: 37)?.score?.value == 4.5)
        #expect(composition.token(atDisplayOffset: 5) == nil)
    }

    @Test("display and plain offsets round trip through each other", arguments: [
        (0, 0), (1, 7), (5, 11), (37, 43), (38, 46), (50, 58)
    ])
    func coordinates(display: Int, plain: Int) {
        let composition = Self.sample()
        #expect(composition.plainOffset(forDisplayOffset: display) == plain)
        #expect(composition.displayOffset(forPlainOffset: plain) == display)
    }

    @Test("a plain offset inside a token clamps to its placeholder")
    func coordinatesInsideToken() {
        let composition = Self.sample()
        #expect(composition.displayOffset(forPlainOffset: 44) == 37)
    }

    // MARK: - Backspace = one unit

    @Test("backspacing a token's placeholder removes the whole token and all its characters")
    func backspaceDeletesTokenWhole() {
        let composition = Self.sample()
        let (next, caret) = composition.applyingDisplayEdit(
            replacing: TextSpan(location: 37, length: 1),
            with: ""
        )
        #expect(next.plain == "Tipo 00 with Jess. The tagliatelle al ragù  was unreal.")
        #expect(next.scores.isEmpty)
        #expect(next.spans.count == 1)
        #expect(caret == 37)
    }

    @Test("a selection that only touches a token still takes it whole — never half a score")
    func selectionSwallowsToken() {
        let composition = Self.sample()
        let (next, _) = composition.applyingDisplayEdit(
            replacing: TextSpan(location: 36, length: 2),
            with: ""
        )
        #expect(next.plain == "Tipo 00 with Jess. The tagliatelle al ragù was unreal.")
        #expect(next.scores.isEmpty)
    }

    @Test("typing before a token shifts it, and the token survives")
    func insertBeforeShifts() {
        let composition = Self.sample()
        let (next, caret) = composition.applyingDisplayEdit(
            replacing: TextSpan(location: 1, length: 0),
            with: ","
        )
        #expect(next.plain.hasPrefix("Tipo 00, with"))
        #expect(next.spans.count == 2)
        #expect(next.spans[1].span.location == 44)
        #expect(caret == 2)
    }

    @Test("typing after a token leaves both tokens alone")
    func insertAfterKeeps() {
        let composition = Self.sample()
        let (next, _) = composition.applyingDisplayEdit(
            replacing: TextSpan(location: 50, length: 0),
            with: " truly"
        )
        #expect(next.spans.count == 2)
        #expect(next.plain.contains("4.5"))
    }

    @Test("replacing the whole text clears every token")
    func replaceAllClears() {
        let composition = Self.sample()
        let display = composition.displayString.utf16.count
        let (next, caret) = composition.applyingDisplayEdit(
            replacing: TextSpan(location: 0, length: display),
            with: "start again"
        )
        #expect(next.plain == "start again")
        #expect(next.spans.isEmpty)
        #expect(caret == 11)
    }

    // MARK: - Inserting and re-scoring

    @Test("the Score key inserts at the caret and adds a space when it lands against a word")
    func insertScoreAtCaret() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "The tiramisu"
        )
        let token = EntryToken(kind: .score(Rating(rounding: 3)))
        let (next, caret) = composition.inserting(token, atDisplayOffset: 12)
        // A space in front of the pill AND one after it: the end of the words is not a word
        // boundary, it is where the next word is about to be typed.
        #expect(next.plain == "The tiramisu 3.0 ")
        #expect(next.displayString == "The tiramisu \u{FFFC} ")
        // …and the caret is after that space, not inside the run the insertion just wrote.
        #expect(caret == 15)
    }

    @Test("no double space when the caret is already after one")
    func insertScoreAfterSpace() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(replacing: TextSpan(location: 0, length: 0), with: "Tiramisu ")
        let (next, _) = composition.inserting(EntryToken(kind: .score(Rating(rounding: 3))), atDisplayOffset: 9)
        #expect(next.plain == "Tiramisu 3.0 ")
    }

    @Test("a token dropped in front of words is spaced off them, so the sentence survives")
    func insertPlaceAtStart() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "with Jess for her birthday"
        )
        let token = EntryToken(kind: .place(PlaceRef(id: UUID(), name: "Tipo 00")))
        let (next, caret) = composition.inserting(token, atDisplayOffset: 0)
        #expect(next.plain == "Tipo 00 with Jess for her birthday")
        #expect(next.spans.first?.span == TextSpan(location: 0, length: 7))
        // The start of the text needed no space; the caret still clears the one the token brought
        // with it on the other side, so typing cannot shove that space down the sentence.
        #expect(caret == 2)
    }

    @Test("a token in the middle of a sentence gets a space on both sides")
    func insertMidSentence() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "The tiramisuwas flat"
        )
        let (next, _) = composition.inserting(EntryToken(kind: .score(Rating(rounding: 3))), atDisplayOffset: 12)
        #expect(next.plain == "The tiramisu 3.0 was flat")
    }

    @Test("a token that lands against punctuation takes no gap — never 'the tiramisu 3.0 ,'")
    func insertBeforePunctuation() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "The tiramisu, then coffee"
        )
        let (next, caret) = composition.inserting(EntryToken(kind: .score(Rating(rounding: 3))), atDisplayOffset: 12)
        #expect(next.plain == "The tiramisu 3.0, then coffee")
        // Nothing was added after the token, so the caret sits against the comma.
        #expect(caret == 14)
    }

    // MARK: - The words round-trip verbatim through a token insert

    /// **The CEO's first real entry on build 45.** It arrived on the server as
    /// `PJ’s Mexican cantinafishbowl margarita  was a 4.5 and elitee`: the place token welded to the
    /// next word, and a doubled gap further along where the token's own space had been pushed to.
    ///
    /// Driven the way the editor drives it — a token at the caret, then one keystroke at a time, then
    /// the promotion the move-on space triggers — because the defect only appears in the sequence.
    @Test("a place picked on an empty composer, then typed against, keeps exactly one space")
    func placeThenTypingRoundTripsVerbatim() {
        let place = EntryToken(kind: .place(PlaceRef(id: UUID(), name: "PJ’s Mexican cantina")))
        var (composition, caret) = EntryComposition().inserting(place, atDisplayOffset: 0)

        // "fishbowl margarita 4.5 " — the space at the end is the move-on that promotes the number.
        for character in "fishbowl margarita 4.5 " {
            (composition, caret) = composition.applyingDisplayEdit(
                replacing: TextSpan(location: caret, length: 0),
                with: String(character)
            )
        }
        #expect(composition.plain == "PJ’s Mexican cantina fishbowl margarita 4.5 ")

        // The editor's move-on check, at the character just typed.
        let found = composition.pendingScoreLiteral(atDisplayOffset: caret - 1)
        #expect(found?.rating.value == 4.5)
        guard let found else { return }
        composition = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .score(found.rating)))
        // Promotion moves no characters but its own, so the caret stays after the move-on space.
        caret = composition.displayOffset(forPlainOffset: composition.plain.utf16.count)

        for character in "was" {
            (composition, caret) = composition.applyingDisplayEdit(
                replacing: TextSpan(location: caret, length: 0),
                with: String(character)
            )
        }

        #expect(composition.plain == "PJ’s Mexican cantina fishbowl margarita 4.5 was")
        #expect(composition.plain.contains("  ") == false, "no gap the person did not type")
        #expect(composition.place?.name == "PJ’s Mexican cantina")
        #expect(composition.scores.map(\.value) == [4.5])
        // Both tokens still cover their own words — the invariant everything downstream reads.
        #expect(composition.spans.count == 2)
    }

    @Test("the space a token brings stays with the token, however much is typed after it")
    func insertedSpaceIsNeverRelocated() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "The tiramisu"
        )
        var caret: Int
        (composition, caret) = composition.inserting(
            EntryToken(kind: .score(Rating(rounding: 4.5))),
            atDisplayOffset: 12
        )
        for character in "was unreal" {
            (composition, caret) = composition.applyingDisplayEdit(
                replacing: TextSpan(location: caret, length: 0),
                with: String(character)
            )
        }
        #expect(composition.plain == "The tiramisu 4.5 was unreal")
        #expect(composition.plain.contains("  ") == false)
    }

    /// The same defect from the other side, and the one that leaves the doubled gap behind: a token
    /// dropped in the middle brings a space with it, and the words typed next must land after that
    /// space rather than shove it down the sentence.
    @Test("a token inserted mid-sentence keeps its gap where it put it")
    func insertedSpaceMidSentenceIsNeverRelocated() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "The tiramisuwas unreal"
        )
        var caret: Int
        (composition, caret) = composition.inserting(
            EntryToken(kind: .score(Rating(rounding: 4.5))),
            atDisplayOffset: 12
        )
        #expect(composition.plain == "The tiramisu 4.5 was unreal")
        for character in "really " {
            (composition, caret) = composition.applyingDisplayEdit(
                replacing: TextSpan(location: caret, length: 0),
                with: String(character)
            )
        }
        // Not "The tiramisu 4.5really  was unreal" — welded to the pill in front and a doubled gap
        // further along, which is the shape the entry arrived in.
        #expect(composition.plain == "The tiramisu 4.5 really was unreal")
        #expect(composition.plain.contains("  ") == false)
    }

    @Test("promotion leaves every space around the literal exactly where it was")
    func promotionTouchesNoWhitespace() {
        let composition = EntryComposition(plain: "The ragù 4 was unreal", spans: [])
        let found = composition.pendingScoreLiteral(atDisplayOffset: 10)
        #expect(found?.rating.value == 4)
        guard let found else { return }
        let promoted = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .score(found.rating)))
        // "4" prints as "4.0" — the only characters promotion may rewrite are the literal's own.
        #expect(promoted.plain == "The ragù 4.0 was unreal")
    }

    @Test("re-scoring a token rewrites only its own characters and shifts what follows")
    func rescore() {
        let composition = Self.sample()
        let id = composition.spans[1].token.id
        let next = composition.replacing(tokenID: id, with: .score(Rating(rounding: 5)))
        #expect(next.plain == "Tipo 00 with Jess. The tagliatelle al ragù 5.0 was unreal.")
        #expect(next.spans.count == 2)
        #expect(next.spans[1].token.id == id)
        #expect(next.spans[1].token.score?.value == 5)
    }

    @Test("renaming a place token re-lengths its span")
    func renamePlace() {
        let composition = Self.sample()
        let id = composition.spans[0].token.id
        let place = PlaceRef(id: UUID(), name: "Tipo 00 Flinders Lane")
        let next = composition.replacing(tokenID: id, with: .place(place))
        #expect(next.plain.hasPrefix("Tipo 00 Flinders Lane with"))
        #expect(next.spans[0].span.length == 21)
        #expect(next.spans[1].span.location == 57)
    }

    @Test("removing a token takes its characters with it")
    func removeToken() {
        let composition = Self.sample()
        let next = composition.removing(tokenID: composition.spans[0].token.id)
        #expect(next.plain == " with Jess. The tagliatelle al ragù 4.5 was unreal.")
        #expect(next.spans.count == 1)
        #expect(next.spans[0].span.location == 36)
    }

    // MARK: - Promotion

    @Test("promoting a typed number keeps the sentence and prints the score to one decimal")
    func promote() {
        var composition = EntryComposition()
        composition = composition.applyingPlainEdit(
            replacing: TextSpan(location: 0, length: 0),
            with: "Tiramisu a bit flat, 3 after that"
        )
        let literal = TextSpan(location: 21, length: 1)
        let next = composition.promoting(plainSpan: literal, to: EntryToken(kind: .score(Rating(rounding: 3))))
        #expect(next.plain == "Tiramisu a bit flat, 3.0 after that")
        #expect(next.spans.count == 1)
        #expect(next.displayString == "Tiramisu a bit flat, \u{FFFC} after that")
    }

    // MARK: - Copy

    @Test("copying a token yields its words, so a paste elsewhere reads as prose")
    func copyPlainText() {
        let composition = Self.sample()
        #expect(composition.plainText(inDisplaySpan: TextSpan(location: 37, length: 1)) == "4.5")
        #expect(composition.plainText(inDisplaySpan: TextSpan(location: 0, length: 1)) == "Tipo 00")
        let all = TextSpan(location: 0, length: composition.displayString.utf16.count)
        #expect(composition.plainText(inDisplaySpan: all) == composition.plain)
    }
}
