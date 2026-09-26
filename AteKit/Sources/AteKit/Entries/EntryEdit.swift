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
        originalPhotos: [EntryCard.Photo] = [],
        photos: [Photo]? = nil
    ) {
        self.entryID = entryID
        self.body = body
        self.originalRestaurantID = originalRestaurantID
        self.restaurantID = restaurantID
        self.tagTokens = tagTokens
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
    public func save(to entries: any EntryService) async throws -> EntryCard {
        try await entries.updateBody(entryID: entryID, body: body)
        if changesPlace, let restaurantID {
            _ = try await entries.correctPlace(entryID: entryID, restaurantID: restaurantID)
        }
        if changesPhotos, let photos {
            try await savePhotos(photos, to: entries)
        }
        return try await entries.entry(id: entryID)
    }

    /// The old name, kept for callers that only ever set words and a place.
    @discardableResult
    public func saveWordsAndPlace(to entries: any EntryService) async throws -> EntryCard {
        try await save(to: entries)
    }

    private func savePhotos(_ photos: [Photo], to entries: any EntryService) async throws {
        let before = Dictionary(originalPhotos.map { ($0.position, $0.url) }, uniquingKeysWith: { first, _ in first })
        for (position, photo) in photos.enumerated() {
            switch photo {
            case .existing(let url):
                guard before[position] != url else { continue }
                try await entries.attachExisting(entryID: entryID, position: position, url: url)
            case .added(let path):
                let file = URL(filePath: path)
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

    /// Step four, after the composer has gone: forced with the chips, unforced without. A sort is
    /// the server adding structure, not the person's write — a failure leaves the words as saved,
    /// and the entry page offers "Print it again".
    public func sort(on entries: any EntryService) async {
        _ = try? await entries.sort(entryID: entryID, force: tagTokens.isEmpty == false, tagTokens: tagTokens)
    }
}
