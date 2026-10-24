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
        let memo = PhotoPairsMemo.shared
        return AtePhotoDishSource(
            pairs: { entryID, _ in
                let read = (try? await entries.photoDishTags(entryID: entryID)) ?? [:]
                guard PhotoDishTag.wantsMatch(read) else {
                    memo.note(read, for: entryID)
                    return read
                }
                await entries.matchPhotosIfNeverMatched(entryID: entryID)
                let matched = (try? await entries.photoDishTags(entryID: entryID)) ?? read
                memo.note(matched, for: entryID)
                return matched
            },
            pick: { entryID, url, reviewIDs in
                do {
                    try await entries.setPhotoDishes(entryID: entryID, photoURL: url, reviewIDs: reviewIDs)
                } catch {
                    return false
                }
                memo.forget(entryID)
                analytics(EntryEvents.corrected(.photo))
                return true
            },
            known: { memo.pairs(for: $0) }
        )
    }
}

/// The pairs read this session, per entry: the shell rebuilds its source on every redraw, so they
/// are kept here. Bounded, oldest out, so a long scroll through the feed never grows it unchecked.
@MainActor
final class PhotoPairsMemo {
    static let shared = PhotoPairsMemo()

    private var held: [UUID: [String: [PhotoDishTag]]] = [:]
    private var order: [UUID] = []
    private static let limit = 200

    func pairs(for entryID: UUID) -> [String: [PhotoDishTag]]? {
        held[entryID]
    }

    func note(_ pairs: [String: [PhotoDishTag]], for entryID: UUID) {
        guard pairs.isEmpty == false else { return forget(entryID) }
        if held.updateValue(pairs, forKey: entryID) == nil { order.append(entryID) }
        if order.count > Self.limit { held[order.removeFirst()] = nil }
    }

    func forget(_ entryID: UUID) {
        held[entryID] = nil
        order.removeAll { $0 == entryID }
    }
}
