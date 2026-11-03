import Foundation
import Testing
@testable import AteKit

/// An entry folded from three posts the same day (0104), exactly as prod holds Eamon's Lazy Coconut
/// lunch: every score's pill is found where its words are.
@Suite("Merged same-day words keep every score pill")
struct MergedWordsTokensTests {
    static let body = "Beach Mezze 3.0, everything was fresh and tasty, but I was hoping for more (better) "
        + "pita bread tbh V \n\nChicken satay skewers 3.5 \n\nLinguine Frutti di Mare 2.0 tasted a bit like "
        + "wiggles pasta tbh, but the Tiger Prawns 4.0 were so fresh and delicious "

    @Test func everyScoreHasItsPill() throws {
        let lines: [Line] = [
            Line("Beach Mezze", 3, 12, "3.0", 0, "Beach Mezze"),
            Line("Chicken Satay Skewers", 3.5, 125, "3.5", 103, "Chicken satay skewers"),
            Line(
                "Linguine Frutti di Mare", 2, 131, "Linguine Frutti di Mare 2.0", 131, "Linguine Frutti di Mare"
            ),
            Line("Tiger Prawns", 4, 204, "Tiger Prawns 4.0", 204, "Tiger Prawns")
        ]
        let card = EntryCard(
            id: UUID(), authorID: UUID(), body: Self.body, orderNumber: 1, sortStatus: .sorted,
            sortedAt: Date(timeIntervalSince1970: 1_793_000_000),
            createdAt: Date(timeIntervalSince1970: 1_792_990_000),
            updatedAt: Date(timeIntervalSince1970: 1_793_600_000),
            items: lines.enumerated().map { index, line in
                EntryCard.Item(
                    reviewID: UUID(), dishID: UUID(), dishName: line.dish, score: Rating(exactly: line.score),
                    position: index + 1,
                    evidenceOffset: line.evidenceAt, evidenceLength: line.evidence.unicodeScalars.count,
                    mentionOffset: line.mentionAt, mentionLength: line.mention.unicodeScalars.count
                )
            }
        )
        let composition = EntryBodyTokens.composition(for: card)
        let units = Array(Self.body.utf16)
        let found = composition.spans.map {
            String(decoding: units[$0.span.location..<$0.span.endLocation], as: UTF16.self)
        }
        #expect(found == ["3.0", "3.5", "2.0", "4.0"])
        #expect(composition.spans.map(\.span.location) == [12, 125, 155, 217])
    }
}

/// One receipt line as prod holds it: dish, score, and where its evidence and mention sit.
private struct Line {
    let dish: String
    let score: Double
    let evidenceAt: Int
    let evidence: String
    let mentionAt: Int
    let mention: String
    init(_ dish: String, _ score: Double, _ evidenceAt: Int, _ evidence: String, _ mentionAt: Int, _ mention: String) {
        (self.dish, self.score, self.evidenceAt) = (dish, score, evidenceAt)
        (self.evidence, self.mentionAt, self.mention) = (evidence, mentionAt, mention)
    }
}
