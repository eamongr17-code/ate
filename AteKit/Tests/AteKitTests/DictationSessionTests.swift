import Foundation
import Testing
@testable import AteKit

/// **Dictation, stitched into somebody's sentence.**
///
/// Every test here is a way the words can be mangled, because that is the only kind of bug this code
/// has: a recogniser hands back the *whole utterance* on every revision, so an append duplicates, a
/// blind replace eats a correction, and an eager promotion mints a score nobody gave. The screen shows
/// none of it — it just reads wrong.
@Suite("Dictation — partial results stitched into the words")
struct DictationSessionTests {

    /// The design's own sentence, as `Composer.dc.html` draws it: words typed, with a place pill in
    /// them, before anybody touches the microphone.
    private func typedWords() -> EntryComposition {
        let place = EntryToken(kind: .place(PlaceRef(id: UUID(), name: "Tipo 00")))
        return EntryComposition(
            plain: "Tipo 00 with Jess for her birthday.",
            spans: [EntryTokenSpan(token: place, span: TextSpan(location: 0, length: 7))]
        )
    }

    private func stream(
        _ transcripts: [String],
        into composition: EntryComposition,
        session: inout DictationSession
    ) -> DictationSession.Update {
        var composition = composition
        var update = DictationSession.Update(
            composition: composition, caretPlainOffset: 0, promotedScores: []
        )
        for transcript in transcripts {
            update = session.apply(transcript: transcript, to: composition)
            composition = update.composition
        }
        return update
    }

    // MARK: - The whole utterance, again

    @Test("a growing partial result replaces itself rather than piling up")
    func growingPartialDoesNotDuplicate() {
        var session = DictationSession(anchor: 0)
        let update = stream(
            ["The", "The tagliatelle", "The tagliatelle al ragù"],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.plain == "The tagliatelle al ragù")
        #expect(update.caretPlainOffset == update.composition.plain.utf16.count)
    }

    @Test("the recogniser changing its mind rewrites the words rather than saying it twice")
    func revisionReplaces() {
        var session = DictationSession(anchor: 0)
        let update = stream(
            ["it was on real", "it was unreal"],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.plain == "it was unreal")
    }

    @Test("dictation lands at the caret, brings one space, and never touches what was typed")
    func joinsTypedWords() {
        let typed = typedWords()
        var session = DictationSession(anchor: typed.plain.utf16.count)
        let update = stream(
            ["The tagliatelle", "The tagliatelle al ragù was unreal"],
            into: typed,
            session: &session
        )
        #expect(update.composition.plain == "Tipo 00 with Jess for her birthday. The tagliatelle al ragù was unreal")
        // The place pill is exactly where it was, still covering its own name.
        #expect(update.composition.spans.count == 1)
        #expect(update.composition.spans[0].span == TextSpan(location: 0, length: 7))
        #expect(update.composition.place?.name == "Tipo 00")
    }

    @Test("dictating into the middle of a sentence brings a space on both sides")
    func insertsMidSentence() {
        let typed = EntryComposition(plain: "the ragù and the tiramisu", spans: [])
        var session = DictationSession(anchor: 12) // after "the ragù and"
        let update = stream(["was unreal"], into: typed, session: &session)
        #expect(update.composition.plain == "the ragù and was unreal the tiramisu")
    }

    // MARK: - Saying a number

    @Test("a number the recogniser has settled becomes the same score token a typed one does")
    func settledNumberBecomesAToken() {
        var session = DictationSession(anchor: 0)
        var update = session.apply(transcript: "the ragù was unreal, 4.5", to: EntryComposition())
        // Still the tail: the recogniser may yet be on its way somewhere else.
        #expect(update.composition.spans.isEmpty)

        update = session.apply(transcript: "the ragù was unreal, 4.5 rich", to: update.composition)
        #expect(update.promotedScores == [Rating(exactly: 4.5)])
        #expect(update.composition.spans.count == 1)
        #expect(update.composition.spans[0].token.score == Rating(exactly: 4.5))
        // The words still read exactly what was said.
        #expect(update.composition.plain == "the ragù was unreal, 4.5 rich")
        // …and the token covers the digits, which is the model's invariant.
        let span = update.composition.spans[0].span
        #expect(update.composition.plainText(inPlainSpan: span) == "4.5")
    }

    @Test("a number still being said is never promoted early — 4 on its way to 4.5")
    func doesNotPromoteHalfSpokenNumber() {
        var session = DictationSession(anchor: 0)
        var update = session.apply(transcript: "the ragù was unreal, 4", to: EntryComposition())
        #expect(update.composition.spans.isEmpty)
        update = session.apply(transcript: "the ragù was unreal, 4.5", to: update.composition)
        #expect(update.composition.spans.isEmpty)
        update = session.apply(transcript: "the ragù was unreal, 4.5 rich", to: update.composition)
        #expect(update.promotedScores == [Rating(exactly: 4.5)])
        #expect(update.composition.scores == [Rating(exactly: 4.5)])
        #expect(update.composition.plain.contains("4.0") == false)
    }

    @Test("a whole number prints like a price, the way a typed one does")
    func wholeNumberPrintsOneDecimal() {
        var session = DictationSession(anchor: 0)
        let update = stream(
            ["the tiramisu was a 3", "the tiramisu was a 3 after that"],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.scores == [Rating(exactly: 3)])
        #expect(update.composition.plain == "the tiramisu was a 3.0 after that")
    }

    @Test("a pill already in the words is never promoted a second time, however many partials follow")
    func doesNotRepromote() {
        var session = DictationSession(anchor: 0)
        var update = stream(
            ["the ragù was unreal, 4.5", "the ragù was unreal, 4.5 rich"],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.spans.count == 1)
        let tokenID = update.composition.spans[0].token.id
        update = stream(
            ["the ragù was unreal, 4.5 rich, glossy", "the ragù was unreal, 4.5 rich, glossy, gone"],
            into: update.composition,
            session: &session
        )
        #expect(update.composition.spans.count == 1)
        #expect(update.composition.spans[0].token.id == tokenID)
        #expect(update.composition.plain == "the ragù was unreal, 4.5 rich, glossy, gone")
        #expect(session.promotedScoreCount == 1)
    }

    @Test("two numbers in one breath are two tokens")
    func twoScores() {
        var session = DictationSession(anchor: 0)
        let update = stream(
            [
                "the ragù was 4.5 and the tiramisu was 3, both",
                "the ragù was 4.5 and the tiramisu was 3, both good"
            ],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.scores == [Rating(exactly: 4.5), Rating(exactly: 3)])
        #expect(update.composition.plain == "the ragù was 4.5 and the tiramisu was 3.0, both good")
    }

    @Test("the utterance ending promotes a number nothing followed")
    func finishPromotesTrailingNumber() {
        var session = DictationSession(anchor: 0)
        var update = session.apply(transcript: "the ragù was unreal, 4.5", to: EntryComposition())
        #expect(update.composition.spans.isEmpty)
        update = session.finish(to: update.composition)
        #expect(update.promotedScores == [Rating(exactly: 4.5)])
        #expect(update.composition.scores == [Rating(exactly: 4.5)])
    }

    @Test("a number that could be anything else is left as words")
    func refusesNonScores() {
        var session = DictationSession(anchor: 0)
        let update = stream(
            ["the bill was 45 dollars for two", "the bill was 45 dollars for two people"],
            into: EntryComposition(),
            session: &session
        )
        #expect(update.composition.spans.isEmpty)
        #expect(update.composition.plain == "the bill was 45 dollars for two people")
    }

    // MARK: - Settling

    @Test("words the recogniser has stopped changing settle; the tail it is still revising does not")
    func settlesFromTheFront() {
        var session = DictationSession(anchor: 0)
        let first = session.apply(transcript: "the tagliatelle al", to: EntryComposition())
        #expect(session.volatilePlainStart == 0) // nothing has been said twice yet

        var update = session.apply(transcript: "the tagliatelle al ragu", to: first.composition)
        // "the tagliatelle al" is common to both, so it is settled; "ragu" is still the live guess,
        // and the volatile run starts at the space in front of it.
        #expect(session.volatilePlainStart == 18)
        #expect(update.composition.plain == "the tagliatelle al ragu")

        update = session.apply(transcript: "the tagliatelle al ragù was", to: update.composition)
        #expect(session.volatilePlainStart == 18)
        #expect(update.composition.plain == "the tagliatelle al ragù was")
    }

    @Test("settling never goes backwards — a word in full ink does not turn grey again")
    func settlingIsMonotonic() {
        var session = DictationSession(anchor: 0)
        let first = session.apply(transcript: "the ragù was unreal", to: EntryComposition())
        let update = session.apply(transcript: "the ragù was unreal and", to: first.composition)
        let settled = session.volatilePlainStart
        _ = session.apply(transcript: "the ragù was", to: update.composition)
        #expect((session.volatilePlainStart ?? .max) >= (settled ?? 0))
    }

    @Test("the whole utterance settles when it ends")
    func finalSettlesEverything() {
        var session = DictationSession(anchor: 0)
        let first = session.apply(transcript: "the ragù", to: EntryComposition())
        let update = session.apply(transcript: "the ragù was unreal", isFinal: true, to: first.composition)
        #expect(session.volatilePlainStart == nil)
        #expect(update.composition.plain == "the ragù was unreal")
    }

    // MARK: - Undo, and edits from elsewhere

    @Test("everything the microphone wrote is one span — which is what makes one undo correct")
    func writtenSpanUndoesTheWholeDictation() {
        let typed = typedWords()
        var session = DictationSession(anchor: typed.plain.utf16.count)
        let update = stream(
            [
                "the tagliatelle was unreal, 4.5",
                "the tagliatelle was unreal, 4.5 rich",
                "the tagliatelle was unreal, 4.5 rich, glossy"
            ],
            into: typed,
            session: &session
        )
        #expect(update.composition.scores == [Rating(exactly: 4.5)])

        let undone = update.composition.applyingPlainEdit(replacing: session.writtenSpan, with: "")
        #expect(undone.plain == typed.plain)
        #expect(undone.spans == typed.spans)
    }

    @Test("an edit made to the words while the microphone is on is not written over")
    func reanchorsAroundAnEditFromElsewhere() {
        var session = DictationSession(anchor: 0)
        var update = stream(["the ragù was unreal"], into: EntryComposition(), session: &session)

        // Something else changes the words — a place attached from the sheet, in front of everything.
        let place = EntryToken(kind: .place(PlaceRef(id: nil, name: "Tipo 00")))
        let (edited, _) = update.composition.inserting(place, atDisplayOffset: 0)
        #expect(edited.plain == "Tipo 00 the ragù was unreal")

        // …and the recogniser carries on sending the whole utterance.
        update = session.apply(transcript: "the ragù was unreal and rich", to: edited)
        #expect(update.composition.place?.name == "Tipo 00")
        #expect(update.composition.plain == "Tipo 00 the ragù was unreal and rich")
        // Said once, not twice.
        #expect(update.composition.plain.ranges(of: "the ragù").count == 1)
    }

    @Test("a word count for the funnel, and it is the utterance's own")
    func wordCount() {
        var session = DictationSession(anchor: 0)
        _ = stream(
            ["the ragù", "the ragù was unreal, 4.5 rich"],
            into: EntryComposition(),
            session: &session
        )
        #expect(session.wordCount == 6)
    }

    @Test("nothing said, nothing written")
    func emptyTranscriptWritesNothing() {
        let typed = typedWords()
        var session = DictationSession(anchor: typed.plain.utf16.count)
        let update = session.apply(transcript: "", to: typed)
        #expect(update.composition == typed)
        #expect(session.isEmpty)
        #expect(session.writtenSpan.length == 0)
    }
}

/// **Undo across a dictation.** The editor writes what the microphone said through the text view's own
/// `replace(_:withText:)` as ONE edit — the smallest one that turns the words before into the words
/// after. These pin that edit: it covers what was said and nothing else, so the undo UIKit registers
/// for it gives back exactly the sentence from before the microphone opened, pills and all.
@Suite("Undo across a dictation — the one edit the editor makes")
struct DictationUndoTests {

    private func typedWords() -> EntryComposition {
        let place = EntryToken(kind: .place(PlaceRef(id: UUID(), name: "Tipo 00")))
        return EntryComposition(
            plain: "Tipo 00 with Jess for her birthday.",
            spans: [EntryTokenSpan(token: place, span: TextSpan(location: 0, length: 7))]
        )
    }

    private func dictated(into before: EntryComposition) -> EntryComposition {
        var session = DictationSession(anchor: before.plain.utf16.count)
        var composition = before
        for transcript in [
            "The tagliatelle al ragu",
            "The tagliatelle al ragù was unreal, 4.5",
            "The tagliatelle al ragù was unreal, 4.5 rich, glossy"
        ] {
            composition = session.apply(transcript: transcript, to: composition).composition
        }
        return session.finish(to: composition).composition
    }

    @Test("the edit covers only what was said — the place pill in front is never part of it")
    func editIsOnlyTheDictatedRun() {
        let before = typedWords()
        let after = dictated(into: before)
        #expect(after.scores == [Rating(exactly: 4.5)])

        let edit = DisplayEdit.between(before.displayString, after.displayString)
        // Starts where the typed words ended: the pill's placeholder at 0 is outside it.
        #expect(edit.span.location == before.displayString.utf16.count)
        #expect(edit.span.length == 0)
        #expect(edit.applied(to: before.displayString) == after.displayString)
    }

    @Test("undoing that edit gives back the words from before the microphone, pill for pill")
    func undoRestoresTheSentence() {
        let before = typedWords()
        let after = dictated(into: before)
        let edit = DisplayEdit.between(before.displayString, after.displayString)

        // UIKit's undo of `replace(range, withText:)` is the inverse replace.
        let inverse = DisplayEdit(
            span: TextSpan(location: edit.span.location, length: edit.replacement.utf16.count),
            replacement: ""
        )
        let undone = inverse.applied(to: after.displayString)
        #expect(undone == before.displayString)

        // …and in the model's terms: the same edit, taken back, leaves the place token untouched.
        let (restored, _) = after.applyingDisplayEdit(replacing: inverse.span, with: "")
        #expect(restored.plain == before.plain)
        #expect(restored.spans == before.spans)
    }

    @Test("dictating into the middle of a sentence touches neither side of it")
    func midSentenceEditIsLocal() {
        let before = EntryComposition(plain: "the ragù and the tiramisu", spans: [])
        var session = DictationSession(anchor: 12)
        let after = session.apply(transcript: "was unreal", isFinal: true, to: before).composition
        let edit = DisplayEdit.between(before.displayString, after.displayString)
        // A pure insertion of what was said plus its one space — which side the space is counted on
        // is the diff's business; nothing either side of the gap is rewritten.
        #expect(edit.span.length == 0)
        #expect((12...13).contains(edit.span.location))
        #expect(edit.replacement.utf16.count == " was unreal".utf16.count)
        #expect(edit.applied(to: before.displayString) == after.displayString)
    }

    @Test("a re-scored pill is no edit at all — its one character does not move")
    func rescoreWritesNothing() {
        let score = EntryToken(kind: .score(Rating(rounding: 3)))
        let before = EntryComposition(
            plain: "tiramisu 3.0",
            spans: [EntryTokenSpan(token: score, span: TextSpan(location: 9, length: 3))]
        )
        let after = before.replacing(tokenID: score.id, with: .score(Rating(rounding: 4.5)))
        #expect(DisplayEdit.between(before.displayString, after.displayString).isEmpty)
    }

    @Test("an emoji is never cut in half at the edge of the edit")
    func surrogatePairsStayWhole() {
        // Two faces sharing their high surrogate: a naive prefix would stop between the halves.
        let edit = DisplayEdit.between("so good 😀", "so good 😃")
        #expect(edit.span == TextSpan(location: 8, length: 2))
        #expect(edit.replacement == "😃")
        #expect(edit.applied(to: "so good 😀") == "so good 😃")
    }
}
