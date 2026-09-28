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
