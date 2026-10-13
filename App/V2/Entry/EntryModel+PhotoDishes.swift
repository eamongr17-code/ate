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
        return AtePhotoDishes(
            choices: choices,
            paired: photoDishes,
            onPick: card.isMine ? { [weak self] url, reviewID in
                await self?.pairPhoto(entryID: entryID, url: url, reviewID: reviewID) ?? false
            } : nil
        )
    }

    func refreshPhotoDishes() async {
        guard let card, card.photos.isEmpty == false else {
            photoDishes = [:]
            return
        }
        if let read = try? await services.entries.photoDishes(entryID: card.id) { photoDishes = read }
    }

    /// `set_review_photo`: this photo is this dish, or no dish. It sticks through later matches.
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
