import AteKit
import Foundation

extension AtePhotoDishSource {
    /// The entry service's own calls: the pairs as stored (0063), your own entry matched first when
    /// it never was, and your fix through `set_review_photo`.
    @MainActor
    static func live(_ services: AteServices) -> AtePhotoDishSource {
        let entries = services.entries
        let analytics = services.analytics
        return AtePhotoDishSource(
            pairs: { entryID, isMine in
                let read = (try? await entries.photoDishes(entryID: entryID)) ?? [:]
                guard read.isEmpty, isMine else { return read }
                await entries.matchPhotosIfNeverMatched(entryID: entryID)
                return (try? await entries.photoDishes(entryID: entryID)) ?? [:]
            },
            pick: { entryID, url, reviewID in
                do {
                    try await entries.setReviewPhoto(entryID: entryID, photoURL: url, reviewID: reviewID)
                } catch {
                    return false
                }
                analytics(EntryEvents.corrected(.photo))
                return true
            }
        )
    }
}
