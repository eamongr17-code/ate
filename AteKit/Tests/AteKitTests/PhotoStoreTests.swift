import Foundation
import Testing
@testable import AteKit

/// 0101: photos on Cloudflare R2. One suite, serialized, because ``PhotoHosts`` is process-wide.
@Suite("Photo store: Supabase or R2", .serialized)
struct PhotoStoreTests {
    @Test("a base is https://host/ and nothing more")
    func validBase() {
        #expect(PhotoHosts.validBase("https://photos.chewsfood.app/")?.host() == "photos.chewsfood.app")
        #expect(PhotoHosts.validBase("http://photos.chewsfood.app/") == nil)
        #expect(PhotoHosts.validBase("https://photos.chewsfood.app/x/") == nil)
        #expect(PhotoHosts.validBase("https://photos.chewsfood.app/?a=1") == nil)
        #expect(PhotoHosts.validBase("https://localhost/") == nil)
        #expect(PhotoHosts.validBase("not a url") == nil)
    }

    @Test("the photo host is the one the server named, and an answer goes stale after ten minutes")
    func hosts() {
        let now = Date()
        PhotoHosts.record(base: PhotoHosts.validBase("https://photos.chewsfood.app/"), at: now)
        #expect(PhotoHosts.isPhotoHost("photos.chewsfood.app"))
        #expect(PhotoHosts.isPhotoHost("PHOTOS.chewsfood.app"))
        #expect(PhotoHosts.isPhotoHost("evil.app") == false)
        #expect(PhotoHosts.freshAnswer(now: now.addingTimeInterval(60))?.base?.host() == "photos.chewsfood.app")
        #expect(PhotoHosts.freshAnswer(now: now.addingTimeInterval(601)) == nil)
        #expect(PhotoHosts.lastBase?.host() == "photos.chewsfood.app", "a stale answer is still the last one heard")

        PhotoHosts.record(base: nil, at: now)
        #expect(PhotoHosts.isPhotoHost("photos.chewsfood.app") == false, "switched back to Supabase")
        #expect(PhotoHosts.freshAnswer(now: now) != nil, "an answer of Supabase is still an answer")
    }

    @Test("an R2 URL maps back to its bucket path, on our host only")
    func storagePath() {
        PhotoHosts.record(base: PhotoHosts.validBase("https://photos.chewsfood.app/"))
        #expect(SupabaseEntryService.storagePath(
            fromPublicURL: "https://photos.chewsfood.app/review-photos/u/e-0.jpg") == "u/e-0.jpg")
        #expect(SupabaseEntryService.storagePath(
            fromPublicURL: "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-0.jpg") == "u/e-0.jpg")
        #expect(SupabaseEntryService.storagePath(
            fromPublicURL: "https://evil.app/review-photos/u/e-0.jpg") == nil)
        #expect(SupabaseEntryService.storagePath(
            fromPublicURL: "https://photos.chewsfood.app/avatars/u/a.jpg") == nil)
        #expect(EntryDeletion(photoPaths: ["u/e-0.jpg"]).storageFiles == ["u/e-0.jpg", "u/e-0_t.jpg"])
        PhotoHosts.record(base: nil)
    }

    @Test("a refusal from the photos Worker is not retried; a 5xx is")
    func failures() {
        #expect(EntryWriteFailure.of(PhotoStoreError(status: 503)) == .offline)
        #expect(EntryWriteFailure.of(PhotoStoreError(status: 429)) == .offline)
        #expect(EntryWriteFailure.of(PhotoStoreError(status: 415)).isRetryable == false)
    }
}
