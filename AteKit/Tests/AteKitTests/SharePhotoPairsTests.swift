import Foundation
import Testing
@testable import AteKit

/// One receipt per dish, on that dish's own photos.
@Suite("Share photos per dish")
struct SharePhotoPairsTests {
    private let soup = UUID()
    private let dumplings = UUID()
    private let photos = [
        EntryCard.Photo(url: "c", position: 2),
        EntryCard.Photo(url: "a", position: 0),
        EntryCard.Photo(url: "b", position: 1)
    ]

    @Test func eachDishGetsItsOwnPhotosInOrder() {
        let tags = [
            "a": [PhotoDishTag(reviewID: soup)],
            "b": [PhotoDishTag(reviewID: dumplings)],
            "c": [PhotoDishTag(reviewID: soup)]
        ]
        let pairs = SharePhotoPairs.positions(reviewIDs: [soup, dumplings], photos: photos, tags: tags)
        #expect(pairs[soup] == [0, 2])
        #expect(pairs[dumplings] == [1])
    }

    @Test func aPhotoOfTwoDishesIsOfferedForBoth() {
        let tags = ["b": [PhotoDishTag(reviewID: soup), PhotoDishTag(reviewID: dumplings)]]
        let pairs = SharePhotoPairs.positions(reviewIDs: [soup, dumplings], photos: photos, tags: tags)
        #expect(pairs[soup] == [1])
        #expect(pairs[dumplings] == [1])
    }

    @Test func aDishWithNoPairedPhotoHasNone() {
        let tags = ["a": [PhotoDishTag(reviewID: soup)]]
        let pairs = SharePhotoPairs.positions(reviewIDs: [soup, dumplings], photos: photos, tags: tags)
        #expect(pairs[soup] == [0])
        #expect(pairs[dumplings] == [])
    }

    @Test func beforeAnyPairingNoDishHasAPhoto() {
        let pairs = SharePhotoPairs.positions(reviewIDs: [soup, dumplings], photos: photos, tags: [:])
        #expect(pairs[soup] == [])
        #expect(pairs[dumplings] == [])
        let stale = ["a": [PhotoDishTag(reviewID: UUID())]]
        #expect(SharePhotoPairs.positions(reviewIDs: [soup], photos: photos, tags: stale)[soup] == [])
    }
}
