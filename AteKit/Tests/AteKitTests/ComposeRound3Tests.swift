import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AteKit

@Suite("Photo thumbnails")
struct PhotoThumbnailTests {
    @Test("the small copy sits beside the full one, named _t.jpg")
    func path() {
        #expect(PhotoThumbnail.path(for: "u/e-0.jpg") == "u/e-0_t.jpg")
        #expect(PhotoThumbnail.path(for: "u/e-2-ab12.jpeg") == "u/e-2-ab12_t.jpg")
        #expect(PhotoThumbnail.path(for: "u.v/e") == "u.v/e_t.jpg")
    }

    @Test("max 480 on the long side, and a JPEG")
    func size() throws {
        let jpeg = try #require(PhotoThumbnail.jpeg(from: Self.jpeg(width: 1600, height: 1200)))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 480)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 360)
    }

    @Test("not an image, no thumbnail")
    func garbage() {
        #expect(PhotoThumbnail.jpeg(from: Data("not a photo".utf8)) == nil)
    }

    @Test("a public URL maps back to its storage path")
    func storagePath() {
        let url = "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-0.jpg"
        #expect(SupabaseEntryService.storagePath(fromPublicURL: url) == "u/e-0.jpg")
        #expect(SupabaseEntryService.storagePath(fromPublicURL: "preview://e/0") == nil)
    }

    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

@Suite("The preview sort's wire")
struct PreviewSortWireTests {
    @Test("preview: true, the words, the chips and the place — no entry id")
    func body() throws {
        let place = UUID()
        let request = SupabaseEntryService.PreviewSortRequest(
            EarlySortInput(body: "cake GF 4.0", tagTokens: [TagToken(offset: 5, length: 2)], restaurantID: place)
        )
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["preview"] as? Bool == true)
        #expect(json["body"] as? String == "cake GF 4.0")
        #expect(json["restaurant_id"] as? String == place.uuidString.lowercased())
        #expect((json["tag_tokens"] as? [[String: Int]]) == [["offset": 5, "length": 2]])
        #expect(json["entry_id"] == nil)
    }
}

@Suite("Place required")
struct PlaceRequiredTests {
    @Test("a 23502 place_required refusal is recognised; other refusals are not")
    func recognised() {
        #expect(EntrySubmissionResult.rejected("PostgrestError(code: 23502, message: place_required)").isPlaceRequired)
        #expect(EntrySubmissionResult.rejected("PostgrestError(code: 42501, message: denied)").isPlaceRequired == false)
    }
}

@Suite("The Diet key")
struct DietKeyTests {
    @Test("at the caret after a dish, the chip goes in with its spaces")
    func afterDish() throws {
        let words = EntryComposition(plain: "the tiramisu", spans: [])
        let (next, caret) = try #require(words.insertingTag(.gf, atDisplayOffset: 12))
        #expect(next.plain == "the tiramisu GF ")
        #expect(next.tags == [.gf])
        #expect(caret == next.displayString.utf16.count)
    }

    @Test("straight after a score, the chip goes between the dish and its score")
    func beforeScore() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 3)!)), span: TextSpan(location: 9, length: 3)
        )
        let words = EntryComposition(plain: "tiramisu 3.0 ", spans: [score])
        let end = words.displayString.utf16.count
        let (next, caret) = try #require(words.insertingTag(.v, atDisplayOffset: end))
        #expect(next.plain == "tiramisu V 3.0 ")
        #expect(next.tagTokens == [TagToken(offset: 9, length: 1)])
        #expect(caret == next.displayString.utf16.count)
    }

    // The four cases the rule is about: a chip belongs to the nearest dish on its LEFT, and goes out
    // as a `tag_token` where it sits — the sorter attaches it to the dish named nearest before it.

    @Test("chip right after a dish: at the caret, sent where it sits")
    func chipRightAfterADish() throws {
        let words = EntryComposition(plain: "The salmon roll", spans: [])
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: 15))
        #expect(next.plain == "The salmon roll GF ")
        #expect(next.tagTokens == [TagToken(offset: 16, length: 2)])
    }

    @Test("chip after a dish and its score: between the two, so it follows the dish")
    func chipAfterADishAndItsScore() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(location: 16, length: 3)
        )
        let words = EntryComposition(plain: "The salmon roll 4.5", spans: [score])
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: words.displayString.utf16.count))
        #expect(next.plain == "The salmon roll GF 4.5")
        #expect(next.tagTokens == [TagToken(offset: 16, length: 2)])
        #expect(next.scores.map(\.value) == [4.5], "the score is untouched")
    }

    @Test("chip several words later: where the person put it, still the dish before it")
    func chipSeveralWordsLater() throws {
        let score = EntryTokenSpan(
            token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(location: 16, length: 3)
        )
        let words = EntryComposition(plain: "The salmon roll 4.5 was great, ", spans: [score])
        let end = words.displayString.utf16.count
        let (next, _) = try #require(words.insertingTag(.gf, atDisplayOffset: end))
        #expect(next.plain == "The salmon roll 4.5 was great, GF ")
        #expect(next.tagTokens == [TagToken(offset: 31, length: 2)])
    }

    @Test("chip with no dish before it: the key inserts nothing")
    func chipWithNoDishBeforeIt() {
        #expect(EntryComposition(plain: "", spans: []).insertingTag(.gf, atDisplayOffset: 0) == nil)
        let small = EntryComposition(plain: "With my ", spans: [])
        #expect(small.insertingTag(.vg, atDisplayOffset: 8) == nil, "small words are never a dish")
        // …and it is what is to the LEFT that counts: a dish after the caret does not help.
        let later = EntryComposition(plain: "and the tiramisu", spans: [])
        #expect(later.insertingTag(.v, atDisplayOffset: 8) == nil)
        #expect(later.insertingTag(.v, atDisplayOffset: 16) != nil)
    }
}

// MARK: - Editing photos

private final class PhotoRecorder: EntryService, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var failBody = false
    var calls: [String] { lock.withLock { log } }
    private func add(_ call: String) { lock.withLock { log.append(call) } }

    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { UUID() }
    func create(_ entry: NewEntry) async throws -> EntryCard { throw URLError(.badURL) }
    func attach(photo: EntryPhotoUpload) async throws {
        add("upload \(photo.position) \(photo.objectName().suffix(11))")
    }
    func attachExisting(entryID: UUID, position: Int, url: String) async throws { add("keep \(position) \(url)") }
    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {
        add("remove from \(position) \(removedURLs)")
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 0, restaurantID: nil, didAttachPlace: false
        )
    }
    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        Page(items: [], requestedLimit: pageSize)
    }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard { try await entry(id: entryID) }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func setTags(reviewID: UUID, tags: [DietTag]) async throws {}
    func updateBody(entryID: UUID, body: String) async throws {
        if failBody { throw URLError(.notConnectedToInternet) }
        add("body")
    }
}

@Suite("Editing an entry's photos")
struct EntryEditPhotoTests {
    private let original = [EntryCard.Photo(url: "a", position: 0), EntryCard.Photo(url: "b", position: 1)]

    private func stagedFile() throws -> String {
        let url = URL.temporaryDirectory.appending(path: "added01.jpg")
        try Data([0xFF]).write(to: url)
        return url.path()
    }

    @Test("untouched photos are not written at all")
    func untouched() async throws {
        let recorder = PhotoRecorder()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "a"), .existing(url: "b")])
        #expect(edit.changesPhotos == false)
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body"])
    }

    @Test("remove the first, add one: the kept one moves up, the new one uploads under its own name")
    func removeAndAdd() async throws {
        let recorder = PhotoRecorder()
        let path = try stagedFile()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "b"), .added(path: path)])
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body", "keep 0 b", "upload 1 added01.jpg", "remove from 2 [\"a\"]"])
    }

    @Test("removing the last photo drops its row")
    func removeLast() async throws {
        let recorder = PhotoRecorder()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "a")])
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body", "remove from 1 [\"b\"]"])
    }

    @Test("a failed write throws — the composer keeps everything and offers Try again")
    func failureThrows() async {
        let recorder = PhotoRecorder()
        recorder.failBody = true
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [])
        await #expect(throws: (any Error).self) { try await edit.save(to: recorder) }
        #expect(recorder.calls.isEmpty)
    }
}
