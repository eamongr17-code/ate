import Foundation
import Testing
@testable import AteKit

@Suite("A score and the full stop after it")
struct ScorePunctuationTests {
    @Test("a typed score ending the sentence still promotes", arguments: [
        ("it was a 4.5.", 4.5), ("the ragù 4.", 4.0), ("the ragù, 3.5.", 3.5)
    ])
    func endOfSentence(text: String, expected: Double) {
        let found = ScoreLiteral.candidate(in: text, caretUTF16: text.utf16.count)
        #expect(found?.rating.value == expected)
        // The span is the digits: the full stop stays a full stop, straight after the pill.
        #expect(found?.span.endLocation == text.utf16.count - 1)
    }

    @Test("a dot with a digit after it is still a decimal mid-number")
    func decimalMidNumber() {
        #expect(ScoreLiteral.candidate(in: "The ragù 4.5 was", caretUTF16: 11) == nil)
    }

    @Test("a full stop typed after a finished number is moving on; after a bare digit it may be a decimal")
    func moveOnAtTheDot() {
        #expect(ScoreLiteral.isMoveOn(".", typedAt: 12, in: "it was a 4.5."))
        #expect(ScoreLiteral.isMoveOn(".", typedAt: 10, in: "it was a 4.") == false)
        #expect(ScoreLiteral.isMoveOn(".", typedAt: 11, in: "we had 10."))
        #expect(ScoreLiteral.isMoveOn(" ", typedAt: 11, in: "it was a 4 "))
        #expect(ScoreLiteral.isMoveOn(",", typedAt: 10, in: "it was a 4,"))
    }

    @Test("promoting at the full stop leaves the stop touching the pill")
    func noGapBeforeTheStop() {
        let text = "it was a 4.5."
        let composition = EntryComposition(plain: text, spans: [])
        let found = composition.pendingScoreLiteral(atDisplayOffset: text.utf16.count)
        let promoted = composition.promoting(plainSpan: found!.span, to: EntryToken(kind: .score(found!.rating)))
        #expect(promoted.plain == "it was a 4.5.")
        #expect(promoted.displayString == "it was a \u{FFFC}.")
    }
}

@Suite("Scores said in words")
struct ScorePhraseTests {
    private func pending(_ text: String) -> (span: TextSpan, rating: Rating)? {
        EntryComposition(plain: text, spans: []).pendingScoreLiteral(atDisplayOffset: text.utf16.count)
    }

    @Test("the spoken and written shapes become the score", arguments: [
        ("the ragù four and a half", 4.5, "four and a half"),
        ("the ragù four point five", 4.5, "four point five"),
        ("the ragù 4 point 5", 4.5, "4 point 5"),
        ("the ragù was a solid four", 4.0, "four"),
        ("the ragù was a four", 4.0, "four"),
        ("the ragù, gave it four", 4.0, "four"),
        ("tiramisu gave it a five", 5.0, "five"),
        ("the ragù solid four", 4.0, "four"),
        ("tiramisu an easy five", 5.0, "five"),
        ("the ragù 4 out of 5", 4.0, "4 out of 5"),
        ("the ragù four out of five", 4.0, "four out of five"),
        ("the ragù 4.5 out of 5", 4.5, "4.5 out of 5"),
        ("the ragù four and a half out of five", 4.5, "four and a half out of five"),
        ("the ragù 3 1/2", 3.5, "3 1/2"),
        ("the ragù Four And A Half", 4.5, "Four And A Half"),
        ("the ragù four and a half.", 4.5, "four and a half")
    ])
    func converts(text: String, expected: Double, phrase: String) {
        let found = pending(text)
        #expect(found?.rating.value == expected, "\(text)")
        guard let found else { return }
        let units = Array(text.utf16)
        let covered = String(decoding: units[found.span.location..<found.span.endLocation], as: UTF16.self)
        #expect(covered == phrase)
    }

    @Test("words that are not a score are left alone", arguments: [
        "we were four",                 // no article, no half, no out-of
        "four of us went",              // leads the sentence
        "a party of four",              // "of" is not a judgement
        "a solid four-hour lunch",      // part of a word
        "we had four and a half hours", // the caret is past it
        "four and a half",              // no dish before it
        "the ragù four point three",    // not a half-step
        "the ragù zero point five out of ten",
        "the ragù seven out of five",
        "four of us had the ragù",
        "the ragù for four of us",
        "a table for four",
        "the ragù a four",                // an article alone is not a scoring phrase
        "there were four and a half",
        "the ragù. Four and a half",      // a new sentence, not straight after the dish
        "we shared it with four",
        "we waited four and a half",    // a duration
        "the queue took about four point five"
    ])
    func rejects(text: String) {
        #expect(pending(text) == nil, "\(text)")
    }

    @Test("a pill that promoted at the space folds the rest of the phrase into it")
    func foldsIntoThePill() {
        let pill = EntryToken(kind: .score(Rating(exactly: 4)!))
        let composition = EntryComposition(
            plain: "the ragù 4.0 and a half",
            spans: [EntryTokenSpan(token: pill, span: TextSpan(location: 9, length: 3))]
        )
        let found = composition.pendingScoreLiteral(atDisplayOffset: composition.displayString.utf16.count)
        #expect(found?.rating.value == 4.5)
        #expect(found?.span == TextSpan(location: 9, length: 14))
        let promoted = composition.promoting(plainSpan: found!.span, to: EntryToken(kind: .score(found!.rating)))
        #expect(promoted.plain == "the ragù 4.5")
        #expect(promoted.scores == [Rating(exactly: 4.5)!])
    }

    @Test("a pill never re-promotes itself, and a phrase never swallows a pill in its middle")
    func guards() {
        let pill = EntryToken(kind: .score(Rating(exactly: 4)!))
        let alone = EntryComposition(
            plain: "the ragù 4.0", spans: [EntryTokenSpan(token: pill, span: TextSpan(location: 9, length: 3))]
        )
        #expect(alone.pendingScoreLiteral(atDisplayOffset: alone.displayString.utf16.count) == nil)
        let six = EntryToken(kind: .score(.blownAway))
        let sixOutOfFive = EntryComposition(
            plain: "the ragù 6.0 out of 5",
            spans: [EntryTokenSpan(token: six, span: TextSpan(location: 9, length: 3))]
        )
        #expect(sixOutOfFive.pendingScoreLiteral(atDisplayOffset: sixOutOfFive.displayString.utf16.count) == nil)
    }

    @Test("the funnel tells a phrase from a number, and counts 6s")
    func events() {
        #expect(EntryEvents.scoreTokenCreated(source: .typed).parameters == ["source": "typed"])
        #expect(EntryEvents.scoreTokenCreated(source: .dictation, isPhrase: true).parameters
            == ["source": "dictation", "form": "phrase"])
        #expect(EntryEvents.scoreSix().name == "entry_score_six")
    }
}
