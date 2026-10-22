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
        var onPick: (@MainActor @Sendable (String, [UUID]) async -> Bool)?
        if card.isMine {
            onPick = { @MainActor [weak self] (url: String, reviewIDs: [UUID]) async -> Bool in
                guard let self else { return false }
                return await self.pairPhoto(entryID: entryID, url: url, reviewIDs: reviewIDs)
            }
        }
        let load: @MainActor @Sendable () async -> [String: [PhotoDishTag]] = { @MainActor [weak self] in
            guard let self else { return [:] }
            await self.pairPhotosIfNeverPaired()
            await self.refreshPhotoDishes()
            return self.photoDishes
        }
        let byline = AtePhotoDishByline.line(who: card.author.map { "@\($0.username)" }, place: card.place?.name)
        return AtePhotoDishes(choices: choices, paired: photoDishes, onPick: onPick, load: load, byline: byline)
    }

    /// An entry, sorted, with photos and not one of them paired: it was posted before matching
    /// existed, or its match failed (14 Oct: photos still had no dish). Or several dishes and none
    /// placed: matched before a photo could hold several (0083). Ask once, whoever's it is; the
    /// server does nothing for an entry it has already matched (and placed).
    func pairPhotosIfNeverPaired() async {
        guard hasAskedToPairPhotos == false, let card,
              card.photos.isEmpty == false, card.items.isEmpty == false,
              photoDishes.isEmpty || (card.items.count > 1 && PhotoDishTag.wantsMatch(photoDishes))
        else { return }
        hasAskedToPairPhotos = true
        await services.entries.matchPhotosIfNeverMatched(entryID: card.id)
        await refreshPhotoDishes()
    }

    func refreshPhotoDishes() async {
        guard let card, card.photos.isEmpty == false else {
            photoDishes = [:]
            return
        }
        if let read = try? await services.entries.photoDishTags(entryID: card.id) { photoDishes = read }
    }

    /// `set_photo_dishes`: this photo is these dishes, or none. Matching never overrides it, and it
    /// outlives a re-sort (0064/0083). A dish that stays keeps where it sits.
    private func pairPhoto(entryID: UUID, url: String, reviewIDs: [UUID]) async -> Bool {
        do {
            try await services.entries.setPhotoDishes(entryID: entryID, photoURL: url, reviewIDs: reviewIDs)
        } catch {
            return false
        }
        services.analytics(EntryEvents.corrected(.photo))
        let kept = photoDishes[url] ?? []
        let next = reviewIDs.map { id in kept.first { $0.reviewID == id } ?? PhotoDishTag(reviewID: id) }
        photoDishes[url] = next.isEmpty ? nil : next
        return true
    }
}
