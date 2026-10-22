import AteKit
import Foundation

extension AtePhotoDishSource {
    /// The entry service's own calls: the pairs as stored (0063/0083), any entry matched first when
    /// it never was, or was before dishes were placed (whoever is looking), and your fix through
    /// `set_photo_dishes`.
    @MainActor
    static func live(_ services: AteServices) -> AtePhotoDishSource {
        let entries = services.entries
        let analytics = services.analytics
        return AtePhotoDishSource(
            pairs: { entryID, _ in
                let read = (try? await entries.photoDishTags(entryID: entryID)) ?? [:]
                guard PhotoDishTag.wantsMatch(read) else { return read }
                await entries.matchPhotosIfNeverMatched(entryID: entryID)
                return (try? await entries.photoDishTags(entryID: entryID)) ?? read
            },
            pick: { entryID, url, reviewIDs in
                do {
                    try await entries.setPhotoDishes(entryID: entryID, photoURL: url, reviewIDs: reviewIDs)
                } catch {
                    return false
                }
                analytics(EntryEvents.corrected(.photo))
                return true
            }
        )
    }
}
