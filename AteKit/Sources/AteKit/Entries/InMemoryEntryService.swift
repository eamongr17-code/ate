#if DEBUG
import Foundation

/// **The whole core loop, in memory** — previews, unit tests, and a simulator drive with no backend.
///
/// `-ate-preview-data` swaps it in at the root. Debug only, in both directions: the type does not
/// exist in a Beta or Release binary, and a launch argument cannot be set on an installed app
/// anyway. The structure it adds comes from ``PreviewSorter``, which carries the same restriction —
/// the server is the single source of structure in anything that ships.
public final class InMemoryEntryService: EntryService, @unchecked Sendable {
    public static let launchArgument = "-ate-preview-data"

    private let lock = NSLock()
    private var entries: [EntryCard] = []
    private var nextOrderNumber: Int
    private let profile: ViewerProfile
    /// How long a sort "takes". Non-zero so the pending state and the receipt printing in are both
    /// reachable on a simulator; zero in tests, which should not wait for theatre.
    private let sortDelay: Duration

    public init(
        viewer: ViewerProfile = .preview,
        entries: [EntryCard] = [],
        firstOrderNumber: Int = 1,
        sortDelay: Duration = .zero
    ) {
        self.profile = viewer
        self.entries = entries.sorted { $0.createdAt > $1.createdAt }
        self.nextOrderNumber = max(firstOrderNumber, (entries.map(\.orderNumber).max() ?? 0) + 1)
        self.sortDelay = sortDelay
    }

    /// The design's own journal: one sorted entry, so the receipt, the slip and the day header all
    /// have something true to draw.
    public static func seeded(sortDelay: Duration = .milliseconds(900)) -> InMemoryEntryService {
        InMemoryEntryService(entries: [.previewSorted], firstOrderNumber: 143, sortDelay: sortDelay)
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
                place: entry.restaurantID.map { EntryCard.Place(id: $0, name: placeName(for: entry)) }
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
        try lock.withLock {
            guard let card = entries.first(where: { $0.id == id }) else {
                throw AteAPIError.notFound(table: EntryCard.table, id: id)
            }
            return card
        }
    }

    public func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        lock.withLock {
            let ordered = entries.sorted {
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

    /// The name the place token carried, read back out of the words. The real server resolves a
    /// name to a row; here the row is whatever they tapped.
    private func placeName(for entry: NewEntry) -> String {
        let first = entry.body.split(separator: " ").prefix(2).joined(separator: " ")
        return first.isEmpty ? "This place" : first
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
