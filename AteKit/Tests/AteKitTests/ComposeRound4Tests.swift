import Foundation
import Testing
@testable import AteKit

// MARK: - The secret 6

@Suite("The secret 6 — a rating, an encoding, and a gesture")
struct SecretSixRatingTests {

    @Test("6 is a rating; 5.5, 6.5 and 7 are not")
    func exactly() {
        #expect(Rating(exactly: 6) == .blownAway)
        #expect(Rating.blownAway.value == 6)
        #expect(Rating(exactly: 5.5) == nil)
        #expect(Rating(exactly: 6.5) == nil)
        #expect(Rating(exactly: 7) == nil)
        #expect(Rating(exactly: 5) == .perfect)
        #expect(Rating.perfect.isPerfect && Rating.blownAway.isBlownAway)
    }

    @Test("nothing a gesture rounds ever reaches it")
    func roundingNeverSix() {
        #expect(Rating(rounding: 6) == .maximum)
        #expect(Rating(rounding: 99) == .maximum)
        #expect(RatingTrack.rating(atX: 10_000, trackWidth: 300) == .maximum)
    }

    @Test("a 6 on the wire decodes, and prints 6.0")
    func wire() throws {
        let decoded = try JSONDecoder().decode([Rating].self, from: Data("[6, 5, 4.5]".utf8))
        #expect(decoded == [.blownAway, .perfect, Rating(exactly: 4.5)!])
        let encoded = try JSONEncoder().encode(Rating.blownAway)
        #expect(String(bytes: encoded, encoding: .utf8) == "6")
        #expect(EntryToken(kind: .score(.blownAway)).plainText == "6.0")
        #expect(ScoreFormat.halfStep(6) == "6.0")
        #expect(ScoreFormat.average(6) == "6.0")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Rating.self, from: Data("5.5".utf8)) }
    }

    @Test("a typed 6 is never a score — in digits or in words")
    func typedSixIsProse() {
        for text in ["the ragù 6", "the ragù 6.", "the ragù 6.0", "the ragù six out of five", "a solid six",
                     "the ragù 6 out of 5"] {
            let composition = EntryComposition(plain: text, spans: [])
            #expect(composition.pendingScoreLiteral(atDisplayOffset: text.utf16.count) == nil, "\(text)")
        }
    }
}

@Suite("The secret 6 — the hold past the end of the slider")
struct SecretSixGestureTests {
    private let width = 300.0

    @Test("reaching 5.0 and resting there is a 5.0, never a 6")
    func restingAtTheEnd() {
        var six = SecretSix()
        six.move(x: width, trackWidth: width, at: 0)
        let charge = six.tick(at: 5)
        #expect(charge == nil)
        #expect(six.rating(onTrack: .maximum) == .maximum)
    }

    @Test("past the end and held for a second, the sixth star comes out")
    func holdUnlocks() {
        var six = SecretSix()
        let moved = six.move(x: width + 30, trackWidth: width, at: 10)
        #expect(moved)
        let half = six.tick(at: 10.5)
        #expect(half == 0.5)
        #expect(six.isUnlocked == false)
        let full = six.tick(at: 11.0)
        #expect(full == 1)
        #expect(six.isUnlocked)
        #expect(six.rating(onTrack: .maximum) == .blownAway)
        six.lift()
        #expect(six.isUnlocked, "lifting keeps the 6")
    }

    @Test("retreating inside cancels a charge; lifting early drops it")
    func cancel() {
        var six = SecretSix()
        six.move(x: width + 30, trackWidth: width, at: 0)
        six.move(x: width + 2, trackWidth: width, at: 0.5)
        let cancelled = six.tick(at: 2)
        #expect(cancelled == nil)
        #expect(six.isUnlocked == false)

        six.move(x: width + 30, trackWidth: width, at: 3)
        six.lift()
        let dropped = six.tick(at: 9)
        #expect(dropped == nil)
    }

    @Test("an unlocked 6 survives a wobble at the end, and lets go well inside")
    func release() {
        var six = SecretSix()
        six.reset(to: .blownAway)
        #expect(six.isUnlocked, "a pill already on 6 opens unlocked")
        six.move(x: width - 20, trackWidth: width, at: 0)
        #expect(six.isUnlocked)
        six.move(x: width - 60, trackWidth: width, at: 0)
        #expect(six.isUnlocked == false)
        #expect(six.rating(onTrack: Rating(exactly: 4)!) == Rating(exactly: 4))
    }

    @Test("the rubber band: nothing on the track, resistance past it, never a wall")
    func stretch() {
        #expect(SecretSix.stretch(overshoot: -5) == 0)
        #expect(SecretSix.stretch(overshoot: 0) == 0)
        let small = SecretSix.stretch(overshoot: 12)
        let far = SecretSix.stretch(overshoot: 400)
        #expect(small > 0 && small < 12)
        #expect(far > small && far < SecretSix.maxStretch)
    }
}

@Suite("six_tokens — located, sent, and kept through edits")
struct SixTokensTests {
    /// "Tiramisu ★6.0 honestly" — one pill, marked 6 on the slider.
    private func withSix(_ prefix: String = "Tiramisu ") -> EntryComposition {
        let token = EntryToken(kind: .score(.blownAway))
        let plain = "\(prefix)6.0 honestly"
        let location = prefix.utf16.count
        let span = EntryTokenSpan(token: token, span: TextSpan(location: location, length: 3))
        return EntryComposition(plain: plain, spans: [span])
    }

    @Test("a 6 pill is a six token, in Unicode scalars; an ordinary score is not")
    func encoding() {
        #expect(withSix().sixTokens == [TagToken(offset: 9, length: 3)])
        // An emoji earlier in the words is two UTF-16 units and ONE scalar.
        #expect(withSix("🍰 Tiramisu ").sixTokens == [TagToken(offset: 11, length: 3)])
        let five = EntryComposition(plain: "ragù 5.0", spans: [
            EntryTokenSpan(token: EntryToken(kind: .score(.perfect)), span: TextSpan(location: 5, length: 3))
        ])
        #expect(five.sixTokens.isEmpty)
    }

    @Test("the sort request sends six_tokens only when there are any")
    func sortRequest() throws {
        let id = UUID()
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SortEntryRequest(entryID: id, force: false)
        )) as? [String: Any]
        #expect(plain?["six_tokens"] == nil)
        let sixed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SortEntryRequest(entryID: id, force: true, sixTokens: [TagToken(offset: 9, length: 3)])
        )) as? [String: Any]
        let tokens = sixed?["six_tokens"] as? [[String: Int]]
        #expect(tokens == [["offset": 9, "length": 3]])
    }

    @Test("the early sort carries them — a plan cached without a 6 is not the plan for one")
    func earlySort() {
        let place = UUID()
        let input = EarlySortInput(composition: withSix(), restaurantID: place)
        #expect(input?.sixTokens == [TagToken(offset: 9, length: 3)])
        let plain = EarlySortInput(
            composition: EntryComposition(plain: "Tiramisu 6.0 honestly", spans: []), restaurantID: place
        )
        #expect(plain?.sixTokens == [])
        #expect(input != plain)
    }

    @Test("typing before a 6 moves it; the pill and its token survive")
    func survivesTyping() {
        let (edited, _) = withSix().applyingDisplayEdit(replacing: TextSpan(location: 0, length: 0), with: "The ")
        #expect(edited.scores == [.blownAway])
        #expect(edited.plain == "The Tiramisu 6.0 honestly")
        #expect(edited.sixTokens == [TagToken(offset: 13, length: 3)])
    }

    @Test("a draft holding a 6 comes back holding a 6")
    func survivesTheDraft() throws {
        let draft = EntryDraft(composition: withSix())
        let decoded = try JSONDecoder().decode(EntryDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded.composition.scores == [.blownAway])
        #expect(decoded.composition.sixTokens == [TagToken(offset: 9, length: 3)])
    }

    @Test("re-opening a saved entry scored 6 puts the 6 pill back in its words")
    func survivesReopening() {
        let card = EntryCard(
            id: UUID(), authorID: UUID(), body: "Tiramisu 6.0 honestly", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(),
            items: [EntryCard.Item(
                reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu", score: .blownAway, position: 1,
                evidenceOffset: 9, evidenceLength: 3, mentionOffset: 0, mentionLength: 8
            )]
        )
        let composition = EntryBodyTokens.composition(for: card)
        #expect(composition.scores == [.blownAway])
        #expect(composition.sixTokens == [TagToken(offset: 9, length: 3)])
    }

    @Test("an edit's re-sort carries the 6, and so does the Summary's re-print")
    func survivesTheResort() async throws {
        let service = SixRecorder()
        let composition = withSix()
        let edit = EntryEdit(
            entryID: UUID(), body: composition.plain, originalRestaurantID: nil, restaurantID: nil,
            tagTokens: [TagToken(offset: 0, length: 2)], sixTokens: composition.sixTokens
        )
        await edit.sort(on: service)
        #expect(service.sixes == [[TagToken(offset: 9, length: 3)]])

        let actions = EntrySummaryStore.Actions.live(service, tagTokens: [], sixTokens: composition.sixTokens)
        try await actions.resort(UUID())
        #expect(service.sixes.last == [TagToken(offset: 9, length: 3)])
    }

    @Test("a queued entry keeps its six tokens on disk, and an old queue still reads")
    func outbox() throws {
        let insert = QueuedInsert(
            NewEntry(id: UUID(), authorID: UUID(), body: "x", restaurantID: nil, createdAt: Date())
        )
        let queued = QueuedEntry(
            entry: insert, pendingPhotos: [], hasInserted: true, sixTokens: [TagToken(offset: 1, length: 3)]
        )
        let decoded = try JSONDecoder().decode(QueuedEntry.self, from: JSONEncoder().encode(queued))
        #expect(decoded.sixTokens == [TagToken(offset: 1, length: 3)])
        let bare = QueuedEntry(entry: insert, pendingPhotos: [], hasInserted: true)
        #expect(bare.sixTokens == nil)
    }
}

@Suite("Editing the words reaches the server")
struct EditResortTests {
    private func score(_ value: Double, at location: Int) -> EntryTokenSpan {
        let token = EntryToken(kind: .score(Rating(exactly: value)!))
        return EntryTokenSpan(token: token, span: TextSpan(location: location, length: 3))
    }

    private func edit(
        from opened: EntryComposition, to now: EntryComposition, photos: [EntryEdit.Photo]? = nil
    ) -> EntryEdit {
        EntryEdit(
            entryID: UUID(), body: now.plain, originalRestaurantID: nil, restaurantID: nil,
            tagTokens: now.tagTokens, sixTokens: now.sixTokens,
            originalPhotos: [EntryCard.Photo(url: "a", position: 0)], photos: photos,
            tags: EditTagDiff(original: opened, current: now, items: []),
            originalBody: opened.plain
        )
    }

    @Test("a score changed in an edit (3.5 → 4.0) goes to a forced sort of the new words")
    func changedScore() async throws {
        let opened = EntryComposition(plain: "Tiramisu 3.5 honestly", spans: [score(3.5, at: 9)])
        let now = opened.replacing(tokenID: opened.spans[0].token.id, with: .score(Rating(exactly: 4)!))
        let service = SixRecorder()
        let change = edit(from: opened, to: now)
        try await change.save(to: service)
        await change.sort(on: service)
        #expect(service.forced == [true])
        #expect(service.sortedBodies == ["Tiramisu 4.0 honestly"])
    }

    @Test("a photo-only edit makes no sort call")
    func photoOnly() async throws {
        let opened = EntryComposition(plain: "Tiramisu 3.5", spans: [score(3.5, at: 9)])
        let service = SixRecorder()
        let change = edit(from: opened, to: opened, photos: [])
        await change.sort(on: service)
        #expect(service.forced.isEmpty)
        #expect(change.skipsSort)
    }

    @Test("a 6 given in an edit is sent as six_tokens on the forced sort")
    func sixAddedInAnEdit() async throws {
        let opened = EntryComposition(plain: "Tiramisu 4.0", spans: [score(4, at: 9)])
        let now = opened.replacing(tokenID: opened.spans[0].token.id, with: .score(.blownAway))
        let service = SixRecorder()
        let change = edit(from: opened, to: now)
        try await change.save(to: service)
        await change.sort(on: service)
        #expect(service.forced == [true])
        #expect(service.sixes == [[TagToken(offset: 9, length: 3)]])
        #expect(service.sortedBodies == ["Tiramisu 6.0"])
    }
}

/// Records the six tokens every sort was asked with.
private final class SixRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[TagToken]] = []
    private var forces: [Bool] = []
    private var bodies: [String] = []
    var sixes: [[TagToken]] { lock.withLock { log } }
    var forced: [Bool] { lock.withLock { forces } }
    /// The body the server holds at each sort — what it sorts from.
    var sortedBodies: [String] { lock.withLock { bodies } }
    private var body = ""

    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, sixTokens: [])
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], sixTokens: [TagToken]) async throws -> SortOutcome {
        lock.withLock {
            log.append(sixTokens)
            forces.append(force)
            bodies.append(body)
        }
        return SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
        )
    }
    func updateBody(entryID: UUID, body: String) async throws { lock.withLock { self.body = body } }
}

// MARK: - Scores followed by punctuation, and scores said in words

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
