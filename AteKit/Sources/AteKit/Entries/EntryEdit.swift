import Foundation

/// **Saving an edit to an entry that already exists** — everything the composer's keys set, not
/// just the words.
///
/// Four steps, each only when it has something to do:
///
/// 1. **The words** — `entries.body`, the author's own hand.
/// 2. **The place**, when the Place key now holds a different one — `correct_entry_place`, which
///    re-resolves every line at it (and prints a parked plan).
/// 3. **The photos**, when the staged set is not the one the entry had: kept photos re-pointed to
///    their new slots (no bytes move), added ones uploaded, and the rows past the end dropped.
/// 4. **The sort.** Tag chips typed during the edit go to a **forced** re-sort as `tag_tokens` —
///    the only way a chip reaches the server, and the database keeps every line's inherited tags
///    through it. With no new chips the sort is *not* forced: `apply_entry_sort` rebuilds every
///    line, and forcing it for a typo would throw away the dishes the person corrected by hand.
///
/// Steps 1–3 are the person's own writes: every one of them **throws**, so a failed save keeps the
/// composer open with everything in it. Each is idempotent, so "Try again" simply runs them again.
public struct EntryEdit: Sendable {
    /// One slot in the edited photo set, in print order.
    public enum Photo: Sendable, Hashable {
        /// Already in storage — the row is re-pointed, the bytes do not move.
        case existing(url: String)
        /// Staged on the phone during the edit. Uploaded under the staged file's own name, so a
        /// retried save overwrites rather than orphans.
        case added(path: String)
    }

    public let entryID: UUID
    public let body: String
    /// The place the entry had when the composer opened on it.
    public let originalRestaurantID: UUID?
    /// The place on the Place key now.
    public let restaurantID: UUID?
    public let tagTokens: [TagToken]
    /// The secret 6s in the edited words. A forced sort rebuilds every line and the sorter never
    /// reads a 6 out of prose, so a 6 not carried here would be lost to the very re-sort a new chip
    /// asks for.
    public let sixTokens: [TagToken]
    /// Whether the sort after the edit is forced: when the words changed (round 4), or the edit added
    /// a tag chip that was not there when it opened (``EditTagDiff/hasNewTags``). The server rebuilds
    /// only uncorrected lines, so hand corrections survive it; a photo never triggers one.
    public let forcesSort: Bool
    /// The words are not the ones the edit opened on.
    public let changesBody: Bool
    /// Nothing the sorter reads changed (a photo-only edit): no sort call at all.
    public let skipsSort: Bool
    /// Chips deleted during the edit: each line's remaining set, PATCHed as a whole (`setTags`).
    public let tagRemovals: [EditTagDiff.Removal]
    /// The photos the entry had when the composer opened on it, by position.
    public let originalPhotos: [EntryCard.Photo]
    /// The photos staged now, in order. `nil` leaves the entry's photos alone.
    public let photos: [Photo]?

    public init(
        entryID: UUID,
        body: String,
        originalRestaurantID: UUID?,
        restaurantID: UUID?,
        tagTokens: [TagToken],
        sixTokens: [TagToken] = [],
        originalPhotos: [EntryCard.Photo] = [],
        photos: [Photo]? = nil,
        tags: EditTagDiff? = nil,
        originalBody: String? = nil
    ) {
        self.entryID = entryID
        self.body = body
        self.originalRestaurantID = originalRestaurantID
        self.restaurantID = restaurantID
        self.tagTokens = tagTokens
        self.sixTokens = sixTokens
        // No baseline (a caller that only ever adds chips): any chip is new, as before.
        // Round 4: **the words changed, so the sort is forced** — a score changed from 3.5 to 4.0 in an
        // edit used to go nowhere, because an unforced sort is a no-op on a sorted entry. Forcing is safe
        // now: `apply_entry_sort` rebuilds only uncorrected lines, and keeps each line's prior 6 and tags.
        let changesBody = originalBody.map { $0 != body }
        self.changesBody = changesBody ?? false
        self.forcesSort = (changesBody ?? false) || (tags?.hasNewTags ?? (tagTokens.isEmpty == false))
        // With the opening words known, an edit that changed neither them nor the place (photos only)
        // asks the sorter nothing at all. Without them, the old behaviour: always ask, unforced.
        let changesPlace = restaurantID != nil && restaurantID != originalRestaurantID
        self.skipsSort = changesBody == false && forcesSort == false && changesPlace == false
        self.tagRemovals = tags?.removals ?? []
        self.originalPhotos = originalPhotos.sorted { $0.position < $1.position }
        self.photos = photos
    }

    /// A place was picked that the entry does not already have. Clearing a place is not something
    /// the key does, so `nil` never counts as a change.
    public var changesPlace: Bool {
        guard let restaurantID else { return false }
        return restaurantID != originalRestaurantID
    }

    /// Whether the staged photos differ from the entry's.
    public var changesPhotos: Bool {
        guard let photos else { return false }
        return photos != originalPhotos.map { .existing(url: $0.url) }
    }

    /// The kept photos' URLs that are no longer in the set.
    public var removedURLs: [String] {
        guard let photos else { return [] }
        let kept = Set(photos.compactMap { photo -> String? in
            if case .existing(let url) = photo { return url }
            return nil
        })
        return originalPhotos.map(\.url).filter { kept.contains($0) == false }
    }

    /// Steps one to three — the words, the place, the photos — and the row as it now stands. The
    /// words are written first and alone; any failure stops everything and is thrown.
    @discardableResult
    ///
    /// `staged` (round 4): the added photos' files are recorded before they go up and removed only
    /// once the saved entry shows their rows — so a retry after a failed upload still has every file,
    /// and one already confirmed is skipped.
    public func save(to entries: any EntryService, staged: StagedPhotoLedger? = nil) async throws -> EntryCard {
        if let staged { await staged.record(entryID: entryID, photos: addedPhotos) }
        try await entries.updateBody(entryID: entryID, body: body)
        if changesPlace, let restaurantID {
            _ = try await entries.correctPlace(entryID: entryID, restaurantID: restaurantID)
        }
        if changesPhotos, let photos {
            try await savePhotos(photos, to: entries, staged: staged)
        }
        for removal in tagRemovals {
            try await entries.setTags(reviewID: removal.reviewID, tags: removal.remaining)
        }
        let card = try await entries.entry(id: entryID)
        if let staged { await staged.confirm(entryID: entryID, card: card) }
        return card
    }

    /// The photos this edit adds, at their positions.
    public var addedPhotos: [QueuedPhoto] {
        (photos ?? []).enumerated().compactMap { position, photo in
            guard case .added(let path) = photo else { return nil }
            return QueuedPhoto(position: position, path: path)
        }
    }

    /// The old name, kept for callers that only ever set words and a place.
    @discardableResult
    public func saveWordsAndPlace(to entries: any EntryService) async throws -> EntryCard {
        try await save(to: entries)
    }

    private func savePhotos(_ photos: [Photo], to entries: any EntryService, staged: StagedPhotoLedger?) async throws {
        let before = Dictionary(originalPhotos.map { ($0.position, $0.url) }, uniquingKeysWith: { first, _ in first })
        for (position, photo) in photos.enumerated() {
            switch photo {
            case .existing(let url):
                guard before[position] != url else { continue }
                try await entries.attachExisting(entryID: entryID, position: position, url: url)
            case .added(let path):
                let file = URL(filePath: path)
                // Already up and confirmed on an earlier attempt (its file is gone): skip, don't fail.
                if FileManager.default.fileExists(atPath: file.path()) == false,
                   let staged, await staged.isConfirmed(path) { continue }
                let data = try Data(contentsOf: file)
                try await entries.attach(photo: EntryPhotoUpload(
                    entryID: entryID,
                    position: position,
                    data: data,
                    name: file.deletingPathExtension().lastPathComponent
                ))
            }
        }
        if photos.count < originalPhotos.count || removedURLs.isEmpty == false {
            try await entries.removePhotos(
                entryID: entryID, fromPosition: photos.count, removedURLs: removedURLs
            )
        }
    }

    /// Step four, after the composer has gone: forced only for a NEW chip, unforced otherwise. A sort is
    /// the server adding structure, not the person's write — a failure leaves the words as saved,
    /// and the entry page offers "Print it again".
    /// Forced when the words changed, carrying the current `tag_tokens` and `six_tokens`; skipped
    /// entirely for a photo-only edit.
    public func sort(on entries: any EntryService) async {
        guard skipsSort == false else { return }
        _ = try? await entries.sort(
            entryID: entryID, force: forcesSort, tagTokens: tagTokens, sixTokens: sixTokens
        )
    }
}
