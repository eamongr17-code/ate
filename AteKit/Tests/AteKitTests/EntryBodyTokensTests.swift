import Foundation
import Testing
@testable import AteKit

@Suite("Entry body tokens — the server says where, and the matcher is the fallback")
struct EntryBodyTokensTests {

    /// One receipt line, as the wire describes it. `evidence`/`mention` are scalar (offset, length)
    /// pairs exactly as `entry_cards.items[]` carries them; `nil` is the server saying "I cannot point
    /// at this", which is what puts the matcher back in play.
    private struct Line {
        var dish: String
        var score: Double?
        var evidence: (Int, Int)?
        var mention: (Int, Int)?

        init(_ dish: String, _ score: Double?, evidence: (Int, Int)? = nil, mention: (Int, Int)? = nil) {
            self.dish = dish
            self.score = score
            self.evidence = evidence
            self.mention = mention
        }
    }

    private func card(
        _ body: String,
        place: String? = "Tipo 00",
        placeSpan: (Int, Int)? = nil,
        sortedAt: Date? = Date(timeIntervalSince1970: 1_789_000_100),
        updatedAt: Date? = nil,
        items: [Line]
    ) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: UUID(),
            body: body,
            orderNumber: 1,
            sortStatus: .sorted,
            sortedAt: sortedAt,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            updatedAt: updatedAt,
            place: place.map { EntryCard.Place(id: UUID(), name: $0) },
            items: items.enumerated().map { offset, line in
                EntryCard.Item(
                    reviewID: UUID(), dishID: UUID(), dishName: line.dish,
                    score: line.score.flatMap { Rating(exactly: $0) }, position: offset + 1,
                    evidenceOffset: line.evidence?.0, evidenceLength: line.evidence?.1,
                    mentionOffset: line.mention?.0, mentionLength: line.mention?.1
                )
            },
            placeOffset: placeSpan?.0,
            placeLength: placeSpan?.1
        )
    }

    private func slice(_ span: TextSpan, of text: String) -> String {
        let units = Array(text.utf16)
        return String(decoding: units[span.location..<span.endLocation], as: UTF16.self)
    }

    /// The scalar offset of `needle` in `text` — the unit the wire speaks, computed the way the
    /// contract's snippet does, so the fixtures are not hand-counted.
    private func scalars(of needle: String, in text: String) -> (Int, Int) {
        let range = text.range(of: needle)!
        let view = text.unicodeScalars
        let offset = view.distance(from: view.startIndex, to: range.lowerBound.samePosition(in: view)!)
        return (offset, needle.unicodeScalars.count)
    }

    // MARK: - The offsets are used

    @Test("the server's offset wins over the first occurrence the matcher would have taken")
    func offsetsBeatTheMatcher() {
        // Two honest 4.5s and a dish name that is nowhere in the words, so the matcher has no anchor
        // and would take the FIRST. The server points at the second.
        let body = "A 4.5 kind of night. The special 4.5 sealed it."
        let second = scalars(of: "4.5 sealed", in: body)
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("Chef's special", 4.5, evidence: (second.0, 3))]
        ))

        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        #expect(slice(span, of: body) == "4.5")
        #expect(span.location == body.utf16.count - "4.5 sealed it.".utf16.count,
                "the pill sits where the server said, not on the first 4.5")
    }

    @Test("every score pill carries the dish its line was sorted to, so tapping it can open that dish")
    func scorePillsKnowTheirDish() throws {
        let body = "Tipo 00. The ragù 4.5 and the tiramisu 3.5."
        let entry = card(body, items: [Line("Ragù", 4.5), Line("Tiramisu", 3.5)])
        let composition = EntryBodyTokens.composition(for: entry)
        let scores = composition.spans.filter { $0.token.score != nil }
        #expect(scores.map(\.token.dishID) == entry.items.map(\.dishID))
        // A re-score rewrites a pill without losing the dish.
        let first = try #require(scores.first)
        let rescored = composition.replacing(tokenID: first.token.id, with: .score(.maximum))
        #expect(rescored.spans.first { $0.token.id == first.token.id }?.token.dishID == entry.items[0].dishID)
    }

    @Test("a pill the person typed carries no dish")
    func draftPillsHaveNoDish() {
        #expect(EntryToken(kind: .score(.minimum)).dishID == nil)
    }

    @Test("the price-collision body: offsets put the pill on the score, never inside $14.50")
    func priceCollisionWithOffsets() {
        // The QA report's body. `score_evidence` here is the whole phrase — longer than the number,
        // which is legal (migration 0024) — so the pill must cover the digits and leave "out of 5" as
        // words.
        let body = "Paid $14.50 for the pasta and it was worth it, a clear 4.5 out of 5."
        let evidence = scalars(of: "4.5 out of 5", in: body)
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil,
            items: [Line("Pasta", 4.5, evidence: evidence, mention: scalars(of: "pasta", in: body))]
        ))

        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        #expect(slice(span, of: body) == "4.5", "the pill is the number, not the phrase around it")
        #expect(span.location > body.utf16.distance(
            from: body.utf16.startIndex, to: body.range(of: "worth it")!.lowerBound.samePosition(in: body.utf16)!
        ), "and it is the 4.5 they gave, not the one inside the bill total")
        #expect(composition.plain == body, "the words themselves are untouched")
    }

    @Test("the same body with no offsets at all still lands the pill — the matcher is the fallback")
    func priceCollisionWithoutOffsets() {
        let body = "Paid $14.50 for the pasta and it was worth it, a clear 4.5 out of 5."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("pasta", 4.5)]
        ))

        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        #expect(slice(span, of: body) == "4.5")
        #expect(span.location > body.distance(from: body.startIndex, to: body.range(of: "pasta")!.lowerBound))
    }

    @Test("an offset that points outside the body is ignored, not obeyed")
    func offsetOutOfRange() {
        let body = "The ragù 4.5 was unreal."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("ragù", 4.5, evidence: (900, 3))]
        ))
        #expect(composition.spans.count == 1, "it falls back rather than dropping the pill")
        #expect(slice(composition.spans[0].span, of: body) == "4.5")
    }

    @Test("a mention offset anchors the fallback when the evidence offset is null")
    func mentionAnchorsTheFallback() {
        // Two honest 4.0s. The dish is named twice too, and the server points at the SECOND mention,
        // so the second 4.0 is this line's.
        let body = "Tiramisu 4.0 at the start. Much later, another tiramisu 4.0 to finish."
        let second = scalars(of: "tiramisu 4.0 to finish", in: body)
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("Tiramisu", 4.0, mention: (second.0, 8))]
        ))

        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        #expect(slice(span, of: body) == "4.0")
        #expect(span.location > 30, "the 4.0 next to the mention the server pointed at")
    }

    // MARK: - Stale offsets

    @Test("a body edited after the sort falls back rather than trusting a moved offset")
    func staleScoreOffsetFallsBack() {
        // The words were rewritten with no re-sort: `updated_at > sorted_at`, and offset 4 now lands
        // in the middle of a sentence instead of on the score.
        let body = "Last night, finally: the ragù 4.5 was unreal."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil,
            updatedAt: Date(timeIntervalSince1970: 1_789_009_999),
            items: [Line("ragù", 4.5, evidence: (4, 3))]
        ))

        #expect(composition.spans.count == 1)
        #expect(slice(composition.spans[0].span, of: body) == "4.5",
                "the matcher found the digits the stale window had lost")
    }

    @Test("a stale place offset still keeps a number in the place's name from becoming a score")
    func stalePlaceOffset() {
        // The window says "Went ba" (the body was edited since): the matcher finds the real name,
        // claims it, and the ragù's pill goes on the 4.5 that is actually a score.
        let body = "Went back to Bar 4.5 with Jess. The ragù 4.5 was unreal."
        let stale = card(
            body, place: "Bar 4.5", placeSpan: (0, 7),
            updatedAt: Date(timeIntervalSince1970: 1_789_009_999),
            items: [Line("Ragù", 4.5)]
        )
        let composition = EntryBodyTokens.composition(for: stale)
        #expect(composition.spans.count == 1)
        #expect(composition.spans[0].span.location == scalars(of: "4.5 was", in: body).0)
    }

    // MARK: - Unicode

    @Test("a decomposed ragù round-trips: the pill lands, and the words come back exactly as written")
    func decomposedRaguRoundTrips() {
        // NFD: "ragu" + U+0300 combining grave. The dish name arrives precomposed from the menu, which
        // is precisely why the offsets matter — a search for "ragù" finds nothing in these words.
        let body = "The tagliatelle al ragu\u{0300} 4.5 was unreal."
        let evidence = scalars(of: "4.5", in: body)
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil,
            items: [Line("Tagliatelle al rag\u{00F9}", 4.5, evidence: evidence,
                         mention: scalars(of: "tagliatelle al ragu\u{0300}", in: body))]
        ))

        #expect(composition.spans.count == 1)
        #expect(slice(composition.spans[0].span, of: body) == "4.5")
        #expect(composition.plain == body)
        #expect(Array(composition.plain.unicodeScalars) == Array(body.unicodeScalars),
                "nothing normalised the words on the way through")
    }

    @Test("scalar offsets are not UTF-16 offsets: an emoji earlier in the words shifts them")
    func scalarOffsetsAreNotUTF16() {
        // "🍝" is one scalar and two UTF-16 units. Reading the wire's offset as UTF-16 puts the pill
        // one unit early — on the space before the number.
        let body = "🍝 The ragù 4.5 was unreal."
        let evidence = scalars(of: "4.5", in: body)
        #expect(evidence.0 != Array(body.utf16).firstIndex(of: 52), "the two units really do disagree here")

        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("ragù", 4.5, evidence: evidence)]
        ))
        #expect(composition.spans.count == 1)
        #expect(slice(composition.spans[0].span, of: body) == "4.5")
    }

    // MARK: - The matcher's own rules (no offsets)

    @Test("digits either side disqualify an occurrence", arguments: [
        "Table 14.55 and the ragù 4.5 after",
        "It cost 4.50 and the ragù 4.5 after",
        "Bill was 24.5, the ragù 4.5 after"
    ])
    func boundaries(body: String) {
        let composition = EntryBodyTokens.composition(for: card(body, place: nil, items: [Line("ragù", 4.5)]))
        #expect(composition.spans.count == 1)
        let span = composition.spans[0].span
        let before = span.location > 0 ? Array(body.utf16)[span.location - 1] : 32
        #expect(before == 32, "the surviving occurrence is the one after a space")
    }

    @Test("with several honest occurrences, the one nearest the dish wins")
    func nearestTheDish() {
        let body = "The tiramisu 4.0 was fine. The tagliatelle al ragù 4.5 was unreal. Tiramisu 4.0 again."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("Tagliatelle al ragù", 4.5), Line("Tiramisu", 4.0)]
        ))

        #expect(composition.spans.count == 2)
        let scores = composition.spans.compactMap(\.token.score?.value)
        #expect(scores.sorted() == [4.0, 4.5])
        let fourOh = composition.spans.first { $0.token.score?.value == 4.0 }!
        #expect(fourOh.span.location < 20, "the 4.0 beside the first tiramisu, not the one at the end")
    }

    @Test("two items with the same score take different occurrences")
    func sameScoreTwice() {
        let body = "Pork bun 4.0 and the prawn dumpling 4.0, both excellent."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("Pork bun", 4.0), Line("Prawn dumpling", 4.0)]
        ))
        #expect(composition.spans.count == 2)
        #expect(composition.spans[0].span.location != composition.spans[1].span.location)
    }

    @Test("two items pointed at the same evidence do not both claim it")
    func claimedEvidenceIsNotReused() {
        let body = "Pork bun 4.0 and the prawn dumpling 4.0, both excellent."
        let first = scalars(of: "4.0", in: body)
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil,
            items: [Line("Pork bun", 4.0, evidence: first), Line("Prawn dumpling", 4.0, evidence: first)]
        ))
        #expect(composition.spans.count == 2)
        #expect(composition.spans[0].span.location != composition.spans[1].span.location,
                "the second line fell back to the occurrence next to its own dish")
    }

    @Test("an old entry's place is plain text now, and a dish named in different case still matches")
    func placeIsPlainText() {
        // Written when the composer put the place in the words (ComposerPlaceB migration): the name
        // stays exactly where it was typed, as words, and the entry keeps its place.
        let body = "Tipo 00 with Jess. The salmon roll 4.5 was the quiet star."
        let entry = card(body, place: "Tipo 00", placeSpan: (0, 7), items: [Line("Salmon roll", 4.5)])
        let composition = EntryBodyTokens.composition(for: entry)
        #expect(composition.place == nil, "no place pill, ever")
        #expect(composition.plain == body, "not one character of the words moves")
        #expect(composition.scores.map(\.value) == [4.5])
        #expect(entry.place?.name == "Tipo 00", "the entry still has its place")
    }

    // MARK: - Dietary tags

    @Test("a line's tags become chips straight after its dish, in the person's own spelling")
    func tagsAfterTheDish() throws {
        let body = "Tiramisu V 3.0 a bit flat. Jess's prawn spaghetti gf looked the business."
        var entry = card(body, place: nil, items: [Line("Tiramisu", 3.0), Line("Prawn spaghetti", nil)])
        entry = entry.replacing(items: [
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu", score: Rating(exactly: 3),
                           position: 1, tags: [.v]),
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Prawn spaghetti", position: 2,
                           mentionOffset: scalars(of: "prawn spaghetti", in: body).0, mentionLength: 15,
                           tags: [.gf])
        ])
        let composition = EntryBodyTokens.composition(for: entry)
        let tags = composition.spans.filter { $0.token.tag != nil }
        #expect(tags.map { $0.token.tag } == [.v, .gf])
        #expect(slice(try #require(tags.first).span, of: body) == "V", "their capital, kept")
        #expect(composition.scores.map(\.value) == [3.0])
        #expect(composition.plain == body)
    }

    @Test("a tag that is not straight after its dish is never drawn — nothing is invented")
    func tagNotWhereItShouldBe() {
        let body = "Tiramisu 3.0 and it was v good."
        let entry = card(body, place: nil, items: []).replacing(items: [
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu", score: Rating(exactly: 3),
                           position: 1, tags: [.v])
        ])
        #expect(EntryBodyTokens.composition(for: entry).tags.isEmpty)
    }

    @Test("an unscored line contributes no pill, and a score absent from the words is dropped")
    func nothingIsInvented() {
        let body = "The prawn spaghetti looked the business."
        let composition = EntryBodyTokens.composition(for: card(
            body, place: nil, items: [Line("Prawn spaghetti", nil), Line("Tiramisu", 3.0)]
        ))
        #expect(composition.spans.isEmpty, "no number in the words means no pill in the words")
        #expect(composition.plain == body, "and the words are untouched either way")
    }

    @Test("the design's own entry renders through the offsets it ships with")
    func previewFixtureUsesItsOffsets() {
        let composition = EntryBodyTokens.composition(for: .previewSorted)
        let body = EntryCard.previewSorted.body
        #expect(composition.spans.count == 2, "two scores — no place pill, and the unscored line has none")
        #expect(slice(composition.spans[0].span, of: body) == "4.5")
        #expect(slice(composition.spans[1].span, of: body) == "3.0")
    }
}
