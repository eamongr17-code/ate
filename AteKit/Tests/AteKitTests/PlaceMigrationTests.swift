import Foundation
import Testing
@testable import AteKit

/// **ComposerPlaceB (2026-09-26): the place leaves the words.** The Place key holds it now, and
/// typing never mints a place pill. What was already written with one keeps every character — the
/// name is plain text again — and keeps its place.
@Suite("The place moves out of the words")
struct PlaceMigrationTests {
    private let tipo = PlaceRef(id: UUID(), name: "Tipo 00")

    /// Words the way the old composer left them: a place pill at the front, a score pill later on.
    private var legacyWords: EntryComposition {
        let text = "Tipo 00 with Jess. The ragù 4.5 was unreal."
        let score = (text as NSString).range(of: "4.5")
        return EntryComposition(plain: text, spans: [
            EntryTokenSpan(token: EntryToken(kind: .place(tipo)), span: TextSpan(location: 0, length: 7)),
            EntryTokenSpan(token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(score))
        ])
    }

    @Test("stripping a place pill keeps every character and hands the place back")
    func strippingKeepsTheWords() {
        let (words, place) = legacyWords.strippingPlaceTokens()
        #expect(words.plain == legacyWords.plain, "the name stays in the sentence as words")
        #expect(words.place == nil)
        #expect(words.scores.map(\.value) == [4.5], "the score pill is untouched")
        #expect(place == tipo)
    }

    @Test("words with no place pill are returned exactly as they were")
    func nothingToStrip() {
        let plain = EntryComposition(plain: "Just a sandwich.", spans: [])
        let (words, place) = plain.strippingPlaceTokens()
        #expect(words == plain)
        #expect(place == nil)
    }

    @Test("a draft saved with a place pill reopens with the words as text and the place on the key")
    func legacyDraftMigrates() throws {
        // Encoded exactly as a draft on disk was before the change: the pill inside the words, and
        // nothing on the draft itself but the id.
        let legacy = EntryDraft(composition: legacyWords, restaurantID: tipo.id)
        let data = try JSONEncoder().encode(legacy)
        let reopened = try JSONDecoder().decode(EntryDraft.self, from: data)

        #expect(reopened.composition.plain == "Tipo 00 with Jess. The ragù 4.5 was unreal.")
        #expect(reopened.composition.place == nil, "no place pill survives the read")
        #expect(reopened.composition.scores.map(\.value) == [4.5])
        #expect(reopened.placeName == "Tipo 00", "the Place key shows it")
        #expect(reopened.restaurantID == tipo.id, "and the entry is still written with it")
    }

    @Test("a legacy draft whose place was never resolved still keeps its id-less name for the key")
    func legacyDraftWithoutRestaurant() throws {
        let named = PlaceRef(id: UUID(), name: "Tipo 00")
        var words = legacyWords
        words = EntryComposition(plain: words.plain, spans: words.spans.map { span in
            span.token.place == nil ? span : EntryTokenSpan(token: EntryToken(kind: .place(named)), span: span.span)
        })
        let data = try JSONEncoder().encode(EntryDraft(composition: words, restaurantID: nil))
        let reopened = try JSONDecoder().decode(EntryDraft.self, from: data)
        #expect(reopened.restaurantID == named.id, "the pill's id is the place that was tapped")
        #expect(reopened.placeName == "Tipo 00")
    }

    @Test("a new draft round-trips its place name beside its id")
    func placeNameRoundTrips() throws {
        let draft = EntryDraft(
            composition: EntryComposition(plain: "With Jess.", spans: []),
            restaurantID: tipo.id,
            placeName: "Tipo 00"
        )
        let decoded = try JSONDecoder().decode(EntryDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded == draft)
    }
}
