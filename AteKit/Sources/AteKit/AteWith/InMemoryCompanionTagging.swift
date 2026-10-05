#if DEBUG
import Foundation

/// **Tagging in memory** — previews, tests, and `-ate-preview-data`. Holds the same rules the server
/// does where a client can see them: never yourself, never anyone blocked, six seats an entry, a
/// decline sticky.
public final class InMemoryCompanionTagging: CompanionTagging, @unchecked Sendable {
    private struct Tag {
        let id: UUID
        var status: EntryCompanion.Status
    }

    private let lock = NSLock()
    private let viewerID: UUID
    private let people: [CompanionPerson]
    private let blocked: Set<UUID>
    private var recents: [UUID]
    /// entry → person → tag.
    private var tags: [UUID: [UUID: Tag]] = [:]
    /// Tags someone else made with the viewer on them: entry → companion row id.
    private var taggedOnMe: [UUID: UUID] = [:]
    /// Errors the next calls throw, in order — a test's way to make the network fail.
    private var failures: [any Error] = []
    /// Every call that reached the "server", in order.
    private var calls: [String] = []

    public init(
        viewerID: UUID,
        people: [CompanionPerson] = [],
        recents: [UUID] = [],
        blocked: Set<UUID> = []
    ) {
        self.viewerID = viewerID
        self.people = people
        self.recents = recents
        self.blocked = blocked
    }

    /// The preview's people: the seeded feed's three, two more, and Jess and Marcus as the recents.
    public static func seeded(viewerID: UUID) -> InMemoryCompanionTagging {
        typealias Seed = InMemorySocialService.Seed
        let people = [
            CompanionPerson(userID: Seed.jess, handle: "jessw", name: "Jess W"),
            CompanionPerson(userID: Seed.marcus, handle: "marcus.eats", name: "Marcus"),
            CompanionPerson(userID: Seed.priya, handle: "priya", name: "Priya"),
            CompanionPerson(userID: UUID(uuidString: "11111111-0000-4000-8000-000000000005")!,
                            handle: "sam_k", name: "Sam Kowalski"),
            CompanionPerson(userID: UUID(uuidString: "11111111-0000-4000-8000-000000000006")!,
                            handle: "lena.eats", name: "Lena Park")
        ]
        return InMemoryCompanionTagging(viewerID: viewerID, people: people, recents: [Seed.jess, Seed.marcus])
    }

    // MARK: - Test seams

    public func failNext(_ errors: any Error...) {
        lock.withLock { failures.append(contentsOf: errors) }
    }

    /// The people tagged on an entry, and their status.
    public func tagged(on entryID: UUID) -> [UUID: EntryCompanion.Status] {
        lock.withLock { tags[entryID, default: [:]].mapValues(\.status) }
    }

    /// Somebody else tagged the viewer on their entry.
    public func tagViewer(onEntry entryID: UUID) {
        lock.withLock { taggedOnMe[entryID] = UUID() }
    }

    public var callLog: [String] { lock.withLock { calls } }

    // MARK: - CompanionTagging

    public func tag(entryID: UUID, userID: UUID) async throws -> CompanionTagReceipt {
        try lock.withLock {
            try call("tag")
            guard userID != viewerID else { throw CompanionTagError.invalid }
            guard blocked.contains(userID) == false else { throw CompanionTagError.refused }
            guard people.contains(where: { $0.userID == userID }) else { throw CompanionTagError.notFound }
            if let existing = tags[entryID]?[userID] {
                return CompanionTagReceipt(companionID: existing.id, entryID: entryID, userID: userID,
                                           status: existing.status)
            }
            guard tags[entryID, default: [:]].count < CompanionPickerStore.cap else { throw CompanionTagError.limit }
            let tag = Tag(id: UUID(), status: .pending)
            tags[entryID, default: [:]][userID] = tag
            recents.removeAll { $0 == userID }
            recents.insert(userID, at: 0)
            return CompanionTagReceipt(companionID: tag.id, entryID: entryID, userID: userID, status: .pending)
        }
    }

    public func untag(entryID: UUID, userID: UUID) async throws {
        try lock.withLock {
            try call("untag")
            guard let tag = tags[entryID]?[userID], tag.status != .declined else { return }
            tags[entryID]?[userID] = nil
        }
    }

    public func decline(companionID: UUID) async throws {
        try lock.withLock {
            try call("decline")
            guard let entry = taggedOnMe.first(where: { $0.value == companionID })?.key else {
                throw CompanionTagError.notFound
            }
            taggedOnMe[entry] = nil
        }
    }

    public func myTag(onEntry entryID: UUID) async throws -> UUID? {
        try lock.withLock {
            try call("myTag")
            return taggedOnMe[entryID]
        }
    }

    public func recentCompanions(limit: Int) async throws -> [CompanionPerson] {
        try lock.withLock {
            try call("recents")
            let found = recents.compactMap { id in people.first { $0.userID == id } }
                .filter { blocked.contains($0.userID) == false }
            return CompanionRecents.distinct(found, limit: limit)
        }
    }

    public func searchPeople(_ query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<CompanionPerson> {
        try lock.withLock {
            try call("search")
            let ordered = people
                .filter { $0.userID != viewerID && blocked.contains($0.userID) == false && $0.matches(query) }
                .sorted { ($0.handle, $0.userID.uuidString) < ($1.handle, $1.userID.uuidString) }
            var remaining = ordered[...]
            if case .person(_, let handle, let id) = cursor {
                remaining = ordered.drop { ($0.handle, $0.userID.uuidString) <= (handle, id.uuidString) }
            }
            let rows = Array(remaining.prefix(pageSize))
            let next = rows.count < pageSize ? nil : rows.last.map {
                SearchCursor.person(matchTier: 0, username: $0.handle, id: $0.userID)
            }
            return SearchPage(rows: rows, next: next)
        }
    }

    /// Records the call, then throws the next queued failure if there is one. Called under the lock.
    private func call(_ name: String) throws {
        calls.append(name)
        if failures.isEmpty == false { throw failures.removeFirst() }
    }
}
#endif
