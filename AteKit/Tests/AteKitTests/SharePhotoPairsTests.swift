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

    // MARK: - A dish's thumbnail ("Which dishes?", 28 Oct)

    @Test func eachDishIsShownOnItsOwnFirstPhoto() {
        let tags = [
            "a": [PhotoDishTag(reviewID: soup)],
            "b": [PhotoDishTag(reviewID: dumplings)],
            "c": [PhotoDishTag(reviewID: dumplings)]
        ]
        #expect(PhotoDishTag.cover(of: soup, photos: photos, pairs: tags, isOnlyDish: false) == "a")
        #expect(PhotoDishTag.cover(of: dumplings, photos: photos, pairs: tags, isOnlyDish: false) == "b")
    }

    @Test func anUnpairedDishBorrowsNoOtherDishsPhoto() {
        let tags = ["a": [PhotoDishTag(reviewID: soup)]]
        #expect(PhotoDishTag.cover(of: dumplings, photos: photos, pairs: tags, isOnlyDish: false) == nil)
        #expect(PhotoDishTag.cover(of: dumplings, photos: photos, pairs: [:], isOnlyDish: false) == nil)
    }

    @Test func theOnlyDishHasTheFirstPhotoPairedOrNot() {
        #expect(PhotoDishTag.cover(of: soup, photos: photos, pairs: [:], isOnlyDish: true) == "a")
    }
}
