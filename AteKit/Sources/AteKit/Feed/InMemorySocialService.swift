#if DEBUG
import Foundation

/// **The feed, saves and profiles in memory** — previews, the XCUITest drive, and a simulator run
/// with no backend at all (`-ate-preview-data`).
///
/// Debug only, in both directions: the type does not exist in a Beta or Release binary, and a launch
/// argument cannot be set on an installed app. It carries the artboards' own entries, so what a
/// screenshot shows and what `design/v1` draws are the same words, the same dishes and the same
/// scores.
public final class InMemorySocialService: EntryFeedReading, DishSaving, ProfileReading,
                                          PreviewEntryLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [EntryCard]
    private var profiles: [UUID: ProfileSummary]
    private var savedDishIDs: [UUID: Date] = [:]
    private var blocked: Set<UUID> = []

    public init(entries: [EntryCard] = InMemorySocialService.seededEntries,
                profiles: [ProfileSummary] = InMemorySocialService.seededProfiles,
                saved: [UUID] = []) {
        self.entries = entries.sorted { $0.createdAt > $1.createdAt }
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.userID, $0) })
        let now = Date()
        self.savedDishIDs = Dictionary(uniqueKeysWithValues: saved.map { ($0, now) })
    }

    /// The artboards' feed with the artboards' bookmarks already filled — what `-ate-preview-data`
    /// launches into.
    ///
    /// The viewer's own Tipo 00 visit is in there too — never in the feed (it is theirs), but on the
    /// place's page, where your visits lead the list with a "You" byline (`RestaurantVisits`).
    public static func seededWithSaves() -> InMemorySocialService {
        let long = PreviewFaults.longFixtures ? longEntries : []
        return InMemorySocialService(entries: long + seededEntries + [ownVisit], saved: seededSaves)
    }

    /// The viewer's visit, its lines pointed at the seed's own dishes — one tiramisu on the menu,
    /// not two that happen to share a name.
    private static var ownVisit: EntryCard {
        let visit = EntryCard.previewSorted
        let menu = seededEntries.filter { $0.place?.id == visit.place?.id }.flatMap(\.items)
        return visit.replacing(items: visit.items.map { item in
            guard let dishID = menu.first(where: { $0.dishName == item.dishName })?.dishID else { return item }
            return EntryCard.Item(
                reviewID: item.reviewID, dishID: dishID, dishName: item.dishName, score: item.score,
                note: item.note, position: item.position, evidenceOffset: item.evidenceOffset,
                evidenceLength: item.evidenceLength, mentionOffset: item.mentionOffset,
                mentionLength: item.mentionLength, tags: item.tags
            )
        })
    }

    // MARK: - Feed

    public func feedPage(
        after cursor: PageCursor?,
        pageSize: Int,
        includeOwn: Bool,
        area: String?
    ) async throws -> Page<EntryCard> {
        if PreviewFaults.listsOffline { throw URLError(.notConnectedToInternet) }
        return lock.withLock {
            // Every entry is public (0033): the only things that keep one off the feed are a block
            // and whose it is.
            let visible = entries
                .filter { blocked.contains($0.authorID) == false }
                .filter { includeOwn || $0.isMine == false }
                .filter { area == nil || Self.area(of: $0) == area }
                .map(applyingSaves)
            return page(of: visible, after: cursor, pageSize: pageSize)
        }
    }

    /// The feed's areas, as `feed_areas()` counts them: the locality of every visible entry's place.
    public func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        lock.withLock {
            let counts = entries
                .filter { blocked.contains($0.authorID) == false && $0.isMine == false }
                .compactMap(Self.area(of:))
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            let ordered = FeedArea.ordered(counts.map { FeedArea(area: $0.key, count: $0.value) })
            let after = cursor.map { cursor in ordered.filter { FeedArea.isAfter($0, cursor: cursor) } } ?? ordered
            return Array(after.prefix(FeedArea.clampedLimit(limit)))
        }
    }

    /// Where an entry is, for the area filter: its place's locality, as `p_area` matches it.
    private static func area(of card: EntryCard) -> String? {
        card.place?.locality ?? card.place?.city
    }

    // MARK: - Profiles

    public func profile(id: UUID) async throws -> ProfileSummary {
        try lock.withLock {
            guard blocked.contains(id) == false, let summary = profiles[id] else {
                throw AteAPIError.notFound(table: "profiles", id: id)
            }
            return summary
        }
    }

    public func entriesPage(
        authorID: UUID,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        lock.withLock {
            let theirs = entries
                .filter { $0.authorID == authorID && blocked.contains(authorID) == false }
                .map(applyingSaves)
            return page(of: theirs, after: cursor, pageSize: pageSize)
        }
    }

    public func block(userID: UUID) async throws {
        lock.withLock { _ = blocked.insert(userID) }
    }

    public func report(profileID: UUID, reason: String?, note: String?) async throws {}

    public func report(entryID: UUID, reason: String?, note: String?) async throws {}

    // MARK: - Saves

    public func save(dishID: UUID, sourceEntryID: UUID?) async throws {
        lock.withLock { savedDishIDs[dishID] = savedDishIDs[dishID] ?? Date() }
    }

    public func unsave(dishID: UUID) async throws {
        lock.withLock { savedDishIDs[dishID] = nil }
    }

    @discardableResult
    public func saveEntryDishes(entryID: UUID) async throws -> Int {
        lock.withLock {
            guard let entry = entries.first(where: { $0.id == entryID }) else { return 0 }
            for item in entry.items where savedDishIDs[item.dishID] == nil {
                savedDishIDs[item.dishID] = Date()
            }
            return entry.items.count
        }
    }

    static var hidesCovers: Bool { ProcessInfo.processInfo.arguments.contains("-ate-preview-no-covers") }

    public func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        if PreviewFaults.listsOffline { throw URLError(.notConnectedToInternet) }
        return lock.withLock {
            let rows = savedDishIDs.compactMap { dishID, savedAt -> SavedDish? in
                guard let entry = entries.first(where: { card in
                    card.items.contains { $0.dishID == dishID }
                }), let item = entry.items.first(where: { $0.dishID == dishID }),
                      let place = entry.place else { return nil }
                return SavedDish(
                    dishID: dishID,
                    dishName: item.dishName,
                    restaurantID: place.id,
                    restaurantName: place.name,
                    restaurantCity: place.city,
                    dishScore: item.score?.value,
                    // `-ate-preview-no-covers`: dishes nobody has photographed, so the letter tile
                    // (`NoPhotoA`) can be looked at on a simulator.
                    dishCoverURL: Self.hidesCovers ? nil : entry.photos.first?.url,
                    sourceEntryID: entry.id,
                    sourceUserID: entry.authorID,
                    sourceUsername: entry.author?.username,
                    savedAt: savedAt
                )
            }
            .sorted { ($0.savedAt, $0.dishID.uuidString) > ($1.savedAt, $1.dishID.uuidString) }
            let after = cursor.map { cursor in
                rows.filter {
                    ($0.savedAt, $0.dishID.uuidString) < (cursor.createdAt, cursor.id.uuidString)
                }
            } ?? rows
            return Page(items: Array(after.prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    /// Every entry the viewer can see, newest first, with their bookmarks already on it. The place
    /// and dish pages are *derived* from this rather than from a second store, so a preview drive
    /// can never have a dish page that disagrees with the feed behind it (`InMemoryPlaceDishes`).
    func visibleEntriesEverywhere() -> [EntryCard] {
        lock.withLock {
            entries
                .filter { blocked.contains($0.authorID) == false }
                .map(applyingSaves)
        }
    }

    /// One entry, with the viewer's bookmarks on it — what the entry page reads when it is opened
    /// from the feed.
    public func entryCard(id: UUID) -> EntryCard? {
        lock.withLock {
            guard let card = entries.first(where: { $0.id == id }),
                  blocked.contains(card.authorID) == false else { return nil }
            return applyingSaves(card)
        }
    }

    // MARK: - Machinery

    private func applyingSaves(_ card: EntryCard) -> EntryCard {
        card.items.reduce(card) { partial, item in
            partial.settingSaved(dishID: item.dishID, to: savedDishIDs[item.dishID] != nil)
        }
    }

    private func page(of rows: [EntryCard], after cursor: PageCursor?, pageSize: Int) -> Page<EntryCard> {
        let start = cursor.map { cursor in
            rows.filter { ($0.createdAt, $0.id.uuidString) < (cursor.createdAt, cursor.id.uuidString) }
        } ?? rows
        return Page(items: Array(start.prefix(pageSize)), requestedLimit: pageSize)
    }
}
#endif
