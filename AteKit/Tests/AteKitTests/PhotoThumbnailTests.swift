import Foundation
import Testing
@testable import AteKit

@Suite("Photo thumbnails")
struct PhotoThumbnailTests {
    @Test("the small copy sits beside the full one, named _t.jpg")
    func path() {
        #expect(PhotoThumbnail.path(for: "u/e-0.jpg") == "u/e-0_t.jpg")
        #expect(PhotoThumbnail.path(for: "u/e-2-ab12.jpeg") == "u/e-2-ab12_t.jpg")
        #expect(PhotoThumbnail.path(for: "u.v/e") == "u.v/e_t.jpg")
    }

    // The size check needs ImageIO, so it lives in AteTests (AteKitOnAppleTests) and runs on the Mac.
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
}
