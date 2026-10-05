import Foundation

/// **The notifications list, the tags behind it and the push token, in memory** — tests, previews and
/// the `-ate-preview-data` drive. It keeps the server's rules that the screens lean on: newest first
/// on a two-part keyset, a dismissed row gone, answering or declining dismisses the row, a withdrawn
/// tag is `P0002`, an answered one is `23505`, a declined one refuses a post.
public final class InMemoryNotifications: NotificationsReading, AteWithResponding, PushTokenRegistering,
    @unchecked Sendable {
    /// A tag as the server holds it: its notification, the visit, and how it was answered.
    public struct Tag: Sendable {
        public var notification: AteNotification
        public var prefill: AteWithPrefill
        public var dismissed = false
        public var status: AteWithStatus = .pending
        public var responseEntryID: UUID?

        public init(notification: AteNotification, prefill: AteWithPrefill) {
            self.notification = notification
            self.prefill = prefill
        }
    }

    private let lock = NSLock()
    private var tags: [Tag]
    private var nextOrderNumber: Int
    private let viewer: EntryCard.Author
    private let latency: Duration
    /// Every token registered, newest last.
    public private(set) var tokens: [(token: String, environment: APNsEnvironment)] = []
    /// Every card posted, newest last.
    public private(set) var posted: [EntryCard] = []
    /// Fails every list read, for the failed state.
    public var failsReads = false

    public init(
        tags: [Tag] = [],
        viewer: EntryCard.Author = EntryCard.Author(id: UUID(), username: "you"),
        firstOrderNumber: Int = 1,
        latency: Duration = .zero
    ) {
        self.tags = tags
        self.viewer = viewer
        self.nextOrderNumber = firstOrderNumber
        self.latency = latency
    }

    // MARK: - Test and preview hooks

    /// The tagger deleted the entry (or untagged): the tag and its row are gone.
    public func withdraw(companionID: UUID) {
        lock.withLock { tags.removeAll { $0.notification.companionID == companionID } }
    }

    public func tag(companionID: UUID) -> Tag? {
        lock.withLock { tags.first { $0.notification.companionID == companionID } }
    }

    // MARK: - NotificationsReading

    public func notifications(after cursor: PageCursor?, limit: Int) async throws -> NotificationPage {
        try await wait()
        if failsReads { throw AteWithError.unreachable }
        let rows = lock.withLock {
            tags.filter { $0.dismissed == false }
                .map(\.notification)
                .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        }
        let after = rows.filter { row in
            guard let cursor else { return true }
            return (row.createdAt, row.id.uuidString) < (cursor.createdAt, cursor.id.uuidString)
        }
        return NotificationPage(items: Array(after.prefix(limit)), requestedLimit: limit)
    }

    public func unreadCount() async throws -> Int {
        try await wait()
        if failsReads { throw AteWithError.unreachable }
        return lock.withLock { tags.filter { $0.dismissed == false && $0.notification.readAt == nil }.count }
    }

    public func dismiss(notificationID: UUID) async throws {
        try await wait()
        lock.withLock {
            guard let index = tags.firstIndex(where: { $0.notification.id == notificationID }) else { return }
            tags[index].dismissed = true
        }
    }

    // MARK: - AteWithResponding

    public func prefill(companionID: UUID) async throws -> AteWithPrefill {
        try await wait()
        return try lock.withLock {
            guard let index = index(of: companionID) else { throw AteWithError.gone }
            tags[index].notification = tags[index].notification.read()
            let tag = tags[index]
            return AteWithPrefill(
                companionID: companionID, status: tag.status, responseEntryID: tag.responseEntryID,
                entryID: tag.prefill.entryID, visitedAt: tag.prefill.visitedAt, sortStatus: tag.prefill.sortStatus,
                tagger: tag.prefill.tagger, place: tag.prefill.place, dishes: tag.prefill.dishes
            )
        }
    }

    public func respond(companionID: UUID, entryID: UUID, items: [AteWithItem], body: String) async throws
        -> EntryCard {
        try await wait()
        return try lock.withLock {
            guard let index = index(of: companionID) else { throw AteWithError.gone }
            let tag = tags[index]
            switch tag.status {
            case .accepted:
                if tag.responseEntryID == entryID, let card = posted.first(where: { $0.id == entryID }) { return card }
                throw AteWithError.alreadyAnswered
            case .declined:
                throw AteWithError.declined
            case .pending:
                break
            }
            if items.isEmpty, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AteWithError.unreachable
            }
            let known = Dictionary(
                tag.prefill.dishes.map { ($0.dishID, $0.dishName) }, uniquingKeysWith: { first, _ in first }
            )
            var seen: Set<UUID> = []
            var lines: [EntryCard.Item] = []
            for item in items where seen.insert(item.dishID).inserted {
                guard let name = known[item.dishID] else { throw AteWithError.unreachable }
                lines.append(EntryCard.Item(
                    reviewID: UUID(), dishID: item.dishID, dishName: name, score: item.score,
                    position: lines.count + 1, corrected: true
                ))
            }
            let place = tag.prefill.place.map {
                EntryCard.Place(id: $0.id, name: $0.name, address: $0.address, locality: $0.locality)
            }
            let card = EntryCard(
                id: entryID, authorID: viewer.id, body: body, restaurantID: place?.id,
                restaurantSource: place == nil ? nil : "user", orderNumber: nextOrderNumber, sortStatus: .sorted,
                sortedAt: .now, createdAt: tag.prefill.visitedAt, isMine: true, author: viewer, place: place,
                items: lines
            )
            nextOrderNumber += 1
            posted.append(card)
            tags[index].status = .accepted
            tags[index].responseEntryID = entryID
            tags[index].dismissed = true
            return card
        }
    }

    public func decline(companionID: UUID) async throws {
        try await wait()
        try lock.withLock {
            guard let index = index(of: companionID) else { throw AteWithError.gone }
            tags[index].status = .declined
            tags[index].responseEntryID = nil
            tags[index].dismissed = true
        }
    }

    // MARK: - PushTokenRegistering

    public func register(token: String, environment: APNsEnvironment) async throws {
        lock.withLock { tokens.append((token, environment)) }
    }

    public func unregister(token: String) async throws {
        lock.withLock { tokens.removeAll { $0.token == token } }
    }

    // MARK: -

    private func index(of companionID: UUID) -> Int? {
        tags.firstIndex { $0.notification.companionID == companionID }
    }

    private func wait() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }
}

extension AteNotification {
    /// The same row, read.
    func read(at date: Date = .now) -> AteNotification {
        AteNotification(
            id: id, type: type, createdAt: createdAt, readAt: readAt ?? date, actor: actor,
            companionID: companionID, companionStatus: companionStatus, entryID: entryID, place: place,
            visitedAt: visitedAt
        )
    }
}
