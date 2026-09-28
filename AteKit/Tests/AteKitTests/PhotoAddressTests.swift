import Foundation
import Testing
@testable import AteKit

@Suite("Photo addresses")
struct PhotoAddressTests {
    @Test("A thumbnail sits beside its photo: the extension becomes _t.jpg")
    func thumbnailPath() {
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.jpg") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.jpeg") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.HEIC") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "e-0") == "e-0_t.jpg")
        // A dot in a folder is not an extension.
        #expect(PhotoAddress.thumbnailPath(for: "a.b/photo") == "a.b/photo_t.jpg")
    }

    @Test("A thumbnail has no thumbnail, and nothing has none")
    func noThumbnail() {
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0_t.jpg") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "u/") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "u/.jpg") == nil)
    }

    @Test("A public URL's thumbnail keeps its host and query; a fixture has none")
    func thumbnailURL() throws {
        let url = try #require(URL(string:
            "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-1.jpg?v=2"))
        #expect(PhotoAddress.thumbnailURL(for: url)?.absoluteString
            == "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-1_t.jpg?v=2")
        #expect(PhotoAddress.thumbnailURL(for: try #require(URL(string: "asset://ragu"))) == nil)
        #expect(PhotoAddress.thumbnailURL(for: try #require(URL(string: "preview://abc/0"))) == nil)
    }

    @Test("A deleted entry's files: every photo and its thumbnail, once each")
    func withThumbnails() {
        #expect(PhotoAddress.withThumbnails(["u/e-0.jpg", "u/e-1.jpg", "u/e-0.jpg"])
            == ["u/e-0.jpg", "u/e-0_t.jpg", "u/e-1.jpg", "u/e-1_t.jpg"])
        #expect(PhotoAddress.withThumbnails([]) == [])
    }

    @Test("The same address is the same photo, every time; two addresses are two")
    func stableID() {
        let one = PhotoAddress.stableID(for: "https://x/a.jpg")
        #expect(one == PhotoAddress.stableID(for: "https://x/a.jpg"))
        #expect(one != PhotoAddress.stableID(for: "https://x/b.jpg"))
        #expect(PhotoAddress.cacheKey(for: "https://x/a.jpg").count == 64)
    }

    @Test("Prefetch warms the next entries' photos, in scroll order, three from each")
    func upcoming() {
        let entries = [
            BrowseFixtures.card(1, photos: ["a0", "a1"]),
            BrowseFixtures.card(2, photos: ["b0", "b1", "b2", "b3"]),
            BrowseFixtures.card(3),
            BrowseFixtures.card(4, photos: ["d0"])
        ]
        #expect(PhotoAddress.upcoming(in: entries, after: 0) == ["b0", "b1", "b2", "d0"])
        #expect(PhotoAddress.upcoming(in: entries, after: 0, lookahead: 1) == ["b0", "b1", "b2"])
        #expect(PhotoAddress.upcoming(in: entries, after: 3).isEmpty)
        #expect(PhotoAddress.upcoming(in: entries, after: -1, lookahead: 1) == ["a0", "a1"])
    }
}
