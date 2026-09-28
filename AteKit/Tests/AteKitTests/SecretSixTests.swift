import Foundation
import Testing
@testable import AteKit

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

@MainActor
@Suite("The secret 6 — the chart and Ratings")
struct SecretSixChartTests {
    @Test("the histogram carries a 6 bucket, and draws its bar only once a 6 exists")
    func sixBucket() {
        let none = ScoreHistogram([ScoreBucket(score: 4.5, dishCount: 3, reviewCount: 3)])
        #expect(none.buckets.count == 11)
        #expect(none.buckets.last?.score == 6.0)
        #expect(none.drawnScores.count == 10)
        #expect(none.drawnScores.last == 5.0)

        let six = ScoreHistogram([
            ScoreBucket(score: 4.5, dishCount: 3, reviewCount: 3),
            ScoreBucket(score: 6.0, dishCount: 1, reviewCount: 2),
            // Off the grid: there is no 5.5.
            ScoreBucket(score: 5.5, dishCount: 9, reviewCount: 9)
        ])
        #expect(six.dishCount(at: 6.0) == 1)
        #expect(six.dishCount(at: 5.5) == 0)
        #expect(six.drawnScores.last == 6.0)
        #expect(six.highestScore == 6.0)
        #expect(six.total == 4)
    }

    @Test("a 6 snaps to itself; nothing lands on a 5.5")
    func sixSnaps() {
        #expect(ScoreHistogram.snapped(6.0) == 6.0)
        #expect(ScoreHistogram.snapped(7.0) == 6.0)
        #expect(ScoreHistogram.snapped(5.0) == 5.0)
        #expect(ScoreHistogram.snapped(5.4) == 5.0)
        #expect(ScoreFormat.halfStep(6.0) == "6.0")
        #expect(ScoreFormat.average(6.0) == "6.0")
    }

    @Test("Ratings opens on the 6 group first, and settles once")
    func ratingsSix() async {
        let store = RatingsStore(score: 6.0, stats: InMemoryStatsService())
        #expect(store.isSettled == false)
        await store.loadIfNeeded()
        #expect(store.isSettled)
        #expect(store.groups.first?.score == 6.0)
    }
}
