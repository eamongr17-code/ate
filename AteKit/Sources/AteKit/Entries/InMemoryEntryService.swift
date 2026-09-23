#if DEBUG
import Foundation

/// **The whole core loop, in memory** — previews, unit tests, and a simulator drive with no backend.
///
/// `-ate-preview-data` swaps it in at the root. Debug only, in both directions: the type does not
/// exist in a Beta or Release binary, and a launch argument cannot be set on an installed app
/// anyway. The structure it adds comes from ``PreviewSorter``, which carries the same restriction —
/// the server is the single source of structure in anything that ships.
/// Where an entry that is not the viewer's own is read from in preview mode — implemented by
/// ``InMemorySocialService``, so a feed slip opened from the feed lands on a real page **with its
/// bookmarks already true**. Without it the two in-memory services would each hold half the app's
/// state and disagree about what the reader had saved.
public protocol PreviewEntryLookup: Sendable {
    func entryCard(id: UUID) -> EntryCard?
}

public final class InMemoryEntryService: EntryService, @unchecked Sendable {
    public static let launchArgument = "-ate-preview-data"
    /// …and with nothing in it: the first-day journal, which is the one state you cannot reach by
    /// writing something.
    public static let emptyLaunchArgument = "-ate-preview-empty"

    private let lock = NSLock()
    private var entries: [EntryCard] = []
    private var nextOrderNumber: Int
    private let profile: ViewerProfile
    /// How long a sort "takes". Non-zero so the pending state and the receipt printing in are both
    /// reachable on a simulator; zero in tests, which should not wait for theatre.
    private let sortDelay: Duration
    /// Everyone else's entries, read from wherever the feed keeps them.
    private let others: (any PreviewEntryLookup)?

    public init(
        viewer: ViewerProfile = .preview,
        entries: [EntryCard] = [],
        firstOrderNumber: Int = 1,
        sortDelay: Duration = .zero,
        others: (any PreviewEntryLookup)? = nil
    ) {
        self.profile = viewer
        self.entries = entries.sorted { $0.createdAt > $1.createdAt }
        self.nextOrderNumber = max(firstOrderNumber, (entries.map(\.orderNumber).max() ?? 0) + 1)
        self.sortDelay = sortDelay
        self.others = others
    }

    /// The design's own journal: one sorted entry, so the receipt, the slip and the day header all
    /// have something true to draw.
    public static func seeded(
        sortDelay: Duration = .milliseconds(900),
        others: (any PreviewEntryLookup)? = nil
    ) -> InMemoryEntryService {
        InMemoryEntryService(entries: [.previewSorted], firstOrderNumber: 143,
                             sortDelay: sortDelay, others: others)
    }

    public func viewer() async throws -> ViewerProfile { profile }

    public func authorID() async throws -> UUID { profile.id }

    // MARK: - Write

    @discardableResult
    public func create(_ entry: NewEntry) async throws -> EntryCard {
        lock.withLock {
            if let existing = entries.first(where: { $0.id == entry.id }) { return existing }
            let card = EntryCard(
                id: entry.id,
                authorID: entry.authorID,
                body: entry.body,
                visibility: entry.visibility,
                restaurantID: entry.restaurantID,
                restaurantSource: entry.restaurantID == nil ? nil : "user",
                orderNumber: nextOrderNumber,
                sortStatus: .pending,
                createdAt: entry.createdAt,
                isMine: true,
                author: EntryCard.Author(id: profile.id, username: profile.username, city: profile.city),
                place: entry.restaurantID.map(Self.place(id:))
            )
            nextOrderNumber += 1
            entries.insert(card, at: 0)
            return card
        }
    }

    public func attach(photo: EntryPhotoUpload) async throws {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == photo.entryID }) else { return }
            let card = entries[index]
            var photos = card.photos
            photos.removeAll { $0.position == photo.position }
            photos.append(EntryCard.Photo(url: "preview://\(photo.entryID)/\(photo.position)",
                                          position: photo.position))
            entries[index] = card.replacing(photos: photos.sorted { $0.position < $1.position })
        }
    }

    @discardableResult
    public func sort(entryID: UUID, force: Bool) async throws -> SortOutcome {
        if sortDelay > .zero { try? await Task.sleep(for: sortDelay) }
        return lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
                return SortOutcome(entryID: entryID, status: .failed, mode: "preview",
                                   itemCount: 0, restaurantID: nil, didAttachPlace: false)
            }
            let card = entries[index]
            guard card.sortStatus != .sorted || force else {
                return SortOutcome(entryID: entryID, status: .sorted, mode: "preview",
                                   itemCount: card.items.count, restaurantID: card.restaurantID,
                                   didAttachPlace: false)
            }
            // No place ⇒ no dish reviews (a dish needs a restaurant). The entry still sorts; its
            // findings are parked, and attaching the place later prints the receipt retroactively.
            let items = card.restaurantID == nil ? [] : PreviewSorter.sort(body: card.body)
                .enumerated()
                .map { offset, line in
                    EntryCard.Item(
                        reviewID: UUID(), dishID: UUID(), dishName: line.dishName,
                        score: line.score, note: line.note, position: offset + 1
                    )
                }
            entries[index] = card.replacing(sortStatus: .sorted, sortedAt: Date(), items: items)
            return SortOutcome(
                entryID: entryID, status: .sorted, mode: "preview", itemCount: items.count,
                restaurantID: card.restaurantID, didAttachPlace: false
            )
        }
    }

    // MARK: - Read

    public func entry(id: UUID) async throws -> EntryCard {
        if let mine = lock.withLock({ entries.first { $0.id == id } }) { return mine }
        // Not the viewer's — the feed's, then. Opening somebody else's slip has to land on their
        // page, not on a not-found.
        guard let theirs = others?.entryCard(id: id) else {
            throw AteAPIError.notFound(table: EntryCard.table, id: id)
        }
        return theirs
    }

    public func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        lock.withLock {
            let ordered = entries.filter(\.isMine).sorted {
                ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString)
            }
            let remaining: [EntryCard]
            if let cursor {
                remaining = ordered.drop {
                    ($0.createdAt, $0.id.uuidString) >= (cursor.createdAt, cursor.id.uuidString)
                }.map { $0 }
            } else {
                remaining = ordered
            }
            return Page(items: Array(remaining.prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    // MARK: - Corrections

    public func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            entries[index] = entries[index].replacing(
                restaurantID: restaurantID,
                place: EntryCard.Place(id: restaurantID, name: entries[index].place?.name ?? "This place")
            )
        }
        // A place correction re-resolves every line — or prints the parked plan, if the entry had
        // none. Forcing the sort is how this stand-in reproduces that.
        _ = try await sort(entryID: entryID, force: true)
        return try await entry(id: entryID)
    }

    public func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {
        lock.withLock {
            for (index, card) in entries.enumerated() {
                guard card.items.contains(where: { $0.reviewID == reviewID }) else { continue }
                let items = card.items.map { item -> EntryCard.Item in
                    guard item.reviewID == reviewID else { return item }
                    return EntryCard.Item(
                        reviewID: item.reviewID,
                        dishID: dishID ?? item.dishID,
                        dishName: dishName ?? item.dishName,
                        score: item.score, note: item.note, position: item.position, saved: item.saved
                    )
                }
                entries[index] = card.replacing(items: items)
            }
        }
    }

    public func setVisibility(entryID: UUID, visibility: EntryVisibility) async throws {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            entries[index] = entries[index].replacing(visibility: visibility)
        }
    }

    public func updateBody(entryID: UUID, body: String) async throws {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            let card = entries[index]
            entries[index] = EntryCard(
                id: card.id, authorID: card.authorID, body: body, visibility: card.visibility,
                restaurantID: card.restaurantID, restaurantSource: card.restaurantSource,
                orderNumber: card.orderNumber, sortStatus: .pending, createdAt: card.createdAt,
                isMine: card.isMine, author: card.author, place: card.place, photos: card.photos
            )
        }
    }

    /// The place a tapped id belongs to. Reads the same fixtures ``InMemoryPlaceDirectory`` offers,
    /// so a receipt printed in preview mode carries the address the sheet showed rather than a
    /// second, lesser copy of the same place.
    private static func place(id: UUID) -> EntryCard.Place {
        guard let match = InMemoryPlaceDirectory.melbourne.first(where: { $0.restaurantID == id }) else {
            return EntryCard.Place(id: id, name: "This place")
        }
        return EntryCard.Place(id: id, name: match.name, address: match.subtitle, city: "Melbourne")
    }
}

public extension ViewerProfile {
    static let preview = ViewerProfile(
        id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
        username: "eamon",
        name: "Eamon",
        city: "Melbourne"
    )
}
#endif
