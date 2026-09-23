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
                profiles: [ProfileSummary] = InMemorySocialService.seededProfiles) {
        self.entries = entries.sorted { $0.createdAt > $1.createdAt }
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.userID, $0) })
    }

    // MARK: - Feed

    public func feedPage(
        after cursor: PageCursor?,
        pageSize: Int,
        includeOwn: Bool
    ) async throws -> Page<EntryCard> {
        lock.withLock {
            let visible = entries
                .filter { $0.visibility == .public && blocked.contains($0.authorID) == false }
                .filter { includeOwn || $0.isMine == false }
                .map(applyingSaves)
            return page(of: visible, after: cursor, pageSize: pageSize)
        }
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
                .filter { $0.visibility == .public || $0.isMine }
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

    public func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        lock.withLock {
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
                    dishCoverURL: entry.photos.first?.url,
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
