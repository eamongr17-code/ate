import AteKit
import Foundation

extension EntryModel {
    // MARK: - Which photo is which dish

    /// The viewer's dish pill: every photo's dish, and on your own entry the fix.
    var photoDishMenu: AtePhotoDishes? {
        guard let card, card.photos.isEmpty == false, card.items.isEmpty == false else { return nil }
        let choices = card.items.sorted { $0.position < $1.position }
            .map { AtePhotoDishPill.Dish(id: $0.reviewID, name: $0.dishName) }
        let entryID = card.id
        var onPick: (@MainActor @Sendable (String, UUID?) async -> Bool)?
        if card.isMine {
            onPick = { @MainActor [weak self] (url: String, reviewID: UUID?) async -> Bool in
                guard let self else { return false }
                return await self.pairPhoto(entryID: entryID, url: url, reviewID: reviewID)
            }
        }
        return AtePhotoDishes(choices: choices, paired: photoDishes, onPick: onPick)
    }

    func refreshPhotoDishes() async {
        guard let card, card.photos.isEmpty == false else {
            photoDishes = [:]
            return
        }
        if let read = try? await services.entries.photoDishes(entryID: card.id) { photoDishes = read }
    }

    /// `set_review_photo`: this photo is this dish, or no dish. Matching never overrides it, and it
    /// outlives a re-sort (0064).
    private func pairPhoto(entryID: UUID, url: String, reviewID: UUID?) async -> Bool {
        do {
            try await services.entries.setReviewPhoto(entryID: entryID, photoURL: url, reviewID: reviewID)
        } catch {
            return false
        }
        services.analytics(EntryEvents.corrected(.photo))
        var next = photoDishes.filter { $0.key != url && $0.value != reviewID }
        if let reviewID { next[url] = reviewID }
        photoDishes = next
        return true
    }
}
