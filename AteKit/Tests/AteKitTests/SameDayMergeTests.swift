import Foundation
import Testing
@testable import AteKit

@Suite("One place, one day, one entry")
struct SameDayMergeTests {
    private func scored(_ words: String, _ value: Double) throws -> EntryComposition {
        let rating = try #require(Rating(exactly: value))
        let token = EntryToken(kind: .score(rating))
        let text = token.plainText
        let plain = words + " " + text
        let span = TextSpan(location: (words + " ").utf16.count, length: text.utf16.count)
        return EntryComposition(plain: plain, spans: [EntryTokenSpan(token: token, span: span)])
    }

    @Test func theNewWordsFollowTheEarlierOnesAndKeepTheirPills() throws {
        let earlier = try scored("Gnocchi 🍝", 4)
        let later = try scored("Cannoli", 4.5)
        let merged = SameDayMerge.composition(earlier, adding: later)
        #expect(merged.plain == "Gnocchi 🍝 4.0\n\nCannoli 4.5")
        #expect(merged.spans.count == 2, "both pills survive: each still covers its own words")
        #expect(merged.scores.map(\.value) == [4, 4.5])
        #expect(merged.spans.map(\.token.id) == earlier.spans.map(\.token.id) + later.spans.map(\.token.id))
    }

    @Test func aBlankSideAddsNoBreak() throws {
        let words = try scored("Cannoli", 4.5)
        #expect(SameDayMerge.composition(words, adding: EntryComposition()) == words)
        #expect(SameDayMerge.composition(EntryComposition(plain: "  ", spans: []), adding: words) == words)
    }

    @Test func photosKeepTheirOrderThenTheNewOnesOnceAndNoMoreThanTheServerHolds() {
        let earlier = [EntryCard.Photo(url: "b.jpg", position: 1), EntryCard.Photo(url: "a.jpg", position: 0)]
        let merged = SameDayMerge.photos(earlier, adding: [.existing(url: "a.jpg"), .added(path: "/tmp/new.jpg")])
        #expect(merged == [.existing(url: "a.jpg"), .existing(url: "b.jpg"), .added(path: "/tmp/new.jpg")])

        let many = (0..<22).map { EntryCard.Photo(url: "\($0).jpg", position: $0) }
        let added = (0..<5).map { EntryEdit.Photo.added(path: "/tmp/\($0).jpg") }
        #expect(SameDayMerge.photos(many, adding: added).count == SameDayMerge.photoLimit)
    }

    @Test func everyoneStaysAndAnyoneNewIsAdded() {
        let alice = UUID()
        let bob = UUID()
        let cleo = UUID()
        #expect(SameDayMerge.people([alice, bob], adding: [bob, cleo]) == [alice, bob, cleo])
    }
}
