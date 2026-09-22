import Foundation
import Testing
@testable import AteKit

@Suite("Entry draft")
struct EntryDraftTests {

    private func words(_ text: String, scores: [Double] = []) -> EntryComposition {
        var composition = EntryComposition(plain: text, spans: [])
        for value in scores {
            guard let rating = Rating(exactly: value) else { continue }
            let literal = ScoreFormat.halfStep(value)
            guard let range = composition.plain.range(of: literal),
                  let lower = range.lowerBound.samePosition(in: composition.plain.utf16) else { continue }
            let location = composition.plain.utf16.distance(from: composition.plain.utf16.startIndex, to: lower)
            composition = composition.promoting(
                plainSpan: TextSpan(location: location, length: literal.utf16.count),
                to: EntryToken(kind: .score(rating))
            )
        }
        return composition
    }

    @Test("the whole composition survives a round trip through Codable — words and tokens")
    func codableRoundTrip() throws {
        let draft = EntryDraft(
            composition: words("The tagliatelle al ragù 4.5 was unreal.", scores: [4.5]),
            isPublic: false,
            restaurantID: UUID(),
            photoFiles: ["a.jpg", "b.jpg"]
        )

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(EntryDraft.self, from: data)

        #expect(decoded == draft)
        #expect(decoded.composition.plain == "The tagliatelle al ragù 4.5 was unreal.")
        #expect(decoded.composition.scores.map(\.value) == [4.5])
        #expect(decoded.isPublic == false)
        #expect(decoded.photoFiles == ["a.jpg", "b.jpg"])
    }

    @Test("a draft with nothing in it is not worth resuming")
    func emptyDraftIsNotWorthKeeping() {
        #expect(EntryDraft().hasContent == false)
        #expect(EntryDraft(composition: words("Kisume")).hasContent)
        #expect(EntryDraft(photoFiles: ["a.jpg"]).hasContent)
    }

    @Test("seconds from open survive a relaunch instead of restarting")
    func secondsFromOpen() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let draft = EntryDraft(composition: words("Kisume"), startedAt: started)
        #expect(draft.secondsFromOpen(now: started.addingTimeInterval(95)) == 95)
        // A clock that went backwards is not a negative duration.
        #expect(draft.secondsFromOpen(now: started.addingTimeInterval(-10)) == 0)
    }

    @Test("a draft nobody came back to expires after seven days")
    func expiry() {
        let saved = Date(timeIntervalSince1970: 2_000_000)
        let draft = EntryDraft(composition: words("Kisume"), savedAt: saved)
        #expect(draft.isExpired(now: saved.addingTimeInterval(EntryDraft.lifetime - 1)) == false)
        #expect(draft.isExpired(now: saved.addingTimeInterval(EntryDraft.lifetime)))
    }

    @Test("the store hands back what it was given, and an empty draft reads as none")
    func storeRoundTrip() {
        let store = InMemoryEntryDraftStore()
        #expect(store.load() == nil)

        let draft = EntryDraft(composition: words("Tiramisu 3.0 a bit flat.", scores: [3]))
        store.save(draft)
        #expect(store.load()?.id == draft.id)
        #expect(store.load()?.composition.scores.map(\.value) == [3])

        store.save(EntryDraft(id: draft.id))
        #expect(store.load() == nil, "a draft emptied back out is the same as no draft")
    }

    @Test("clearing only clears the draft it names")
    func clearIsScopedToItsOwnDraft() {
        let store = InMemoryEntryDraftStore()
        let mine = EntryDraft(composition: words("Kisume"))
        store.save(mine)

        // A composer that finished long ago must not delete the draft somebody started after it.
        store.clear(draftID: UUID())
        #expect(store.load()?.id == mine.id)

        store.clear(draftID: mine.id)
        #expect(store.load() == nil)
    }

    @Test("an expired draft is dropped rather than offered")
    func expiredDraftIsNotLoaded() {
        let store = InMemoryEntryDraftStore(draft: EntryDraft(
            composition: words("Kisume"),
            savedAt: Date(timeIntervalSince1970: 0)
        ))
        #expect(store.load() == nil)
    }
}
