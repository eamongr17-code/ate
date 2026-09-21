import Foundation
import Testing

@testable import AteKit

@Suite("Score literals — a typed number becoming a token")
struct ScoreLiteralTests {

    private func candidate(_ text: String) -> (span: TextSpan, rating: Rating)? {
        ScoreLiteral.candidate(in: text, caretUTF16: text.utf16.count)
    }

    @Test("the shapes in the design convert", arguments: [
        ("The ragù 4.5", 4.5), ("The ragù, 4.5", 4.5), ("The ragù 4", 4.0),
        ("Tiramisu a bit flat, 3", 3.0), ("salmon roll — 5", 5.0), ("the lot - 0.5", 0.5),
        ("pasta 2.5", 2.5)
    ])
    func converts(text: String, expected: Double) {
        let found = candidate(text)
        #expect(found?.rating.value == expected)
        #expect(found?.span.endLocation == text.utf16.count)
    }

    @Test("the span covers the digits only, never the comma or the space")
    func spanIsTheDigits() {
        let found = candidate("The ragù, 4.5")
        #expect(found?.span == TextSpan(location: 10, length: 3))
    }

    @Test("everything that is not a score is left alone", arguments: [
        "4.7 was the number",     // not a half step
        "we were there at 7",     // out of range
        "opened in 2026",         // a year
        "table 12",               // out of range and two digits
        "it cost $4.5",           // money
        "queued for 4.5km",       // a unit
        "rated it 4.5/5",         // a fraction the person wrote out
        "party of 4 6",           // digit before the number
        "4.5",                    // no words before it
        " 4.5",                   // still no words
        "ragù 0",                 // below the minimum
        "ragù 6",                 // above the maximum
        "ragù 5.5",               // above the maximum
        "ragù #4",                // a symbol leads in
        "ragù4",                  // attached to the word
        "the 10"                  // two digits
    ])
    func rejects(text: String) {
        #expect(candidate(text) == nil)
    }

    @Test("a number mid-sentence converts only when the caret is right after it")
    func caretPosition() {
        let text = "The ragù 4.5 was unreal"
        #expect(ScoreLiteral.candidate(in: text, caretUTF16: 12)?.rating.value == 4.5)
        #expect(ScoreLiteral.candidate(in: text, caretUTF16: 11) == nil) // "4." is not a score
        #expect(ScoreLiteral.candidate(in: text, caretUTF16: 23) == nil) // caret is after "unreal"
    }

    @Test("a number already followed by words still converts — typing on is moving on")
    func followedByWords() {
        #expect(ScoreLiteral.candidate(in: "The ragù 4.5 was unreal", caretUTF16: 12) != nil)
        #expect(ScoreLiteral.candidate(in: "The ragù 4.5, unreal", caretUTF16: 12) != nil)
    }

    @Test("the caret at 0 never converts")
    func emptyText() {
        #expect(ScoreLiteral.candidate(in: "", caretUTF16: 0) == nil)
        #expect(ScoreLiteral.candidate(in: "ragù 4", caretUTF16: 0) == nil)
    }

    @Test("moving on is a space, a newline or sentence punctuation", arguments: [
        " ", "\n", ",", ".", "!", "?", ";", ":"
    ])
    func moveOn(text: String) {
        #expect(ScoreLiteral.isMoveOn(text))
    }

    @Test("typing another digit or a letter is not moving on", arguments: ["5", "k", "/", "-"])
    func notMoveOn(text: String) {
        #expect(ScoreLiteral.isMoveOn(text) == false)
    }
}
