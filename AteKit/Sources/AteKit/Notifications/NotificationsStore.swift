import Foundation

/// **The bell and the list behind it** — one store for both, held once for the app, so a row the
/// respond sheet finishes is gone from the list and the count in the same turn.
///
/// The list is keyset-paged like every list. The X removes its row before the call and puts it back
/// on a refusal (the save action's shape): a one-tap action has to be felt at once. A finished action
/// (posted, declined, or a tag found withdrawn) removes the row for good — the server already has.
@MainActor
@Observable
public final class NotificationsStore {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var rows: [AteNotification] = []
    /// The bell's number. Never below zero; never more than the server says.
    public private(set) var unreadCount = 0
    public private(set) var isLoadingMore = false

    @ObservationIgnored private let reads: any NotificationsReading
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor?
    @ObservationIgnored private var isExhausted = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var inFlight: Set<UUID> = []

    public init(
        reads: any NotificationsReading,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = 30
    ) {
        self.reads = reads
        self.analytics = analytics
        self.pageSize = pageSize
    }

    /// Loaded, and nothing waiting.
    public var isEmpty: Bool { phase == .ready && rows.isEmpty }

    // MARK: - The bell

    /// The count, read again — on foreground and whenever You is shown. A failed read keeps the last.
    public func refreshCount() async {
        guard let count = try? await reads.unreadCount() else { return }
        unreadCount = max(0, count)
    }

    // MARK: - The list

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await load()
    }

    public func refresh() async {
        await load()
    }

    /// The next page, asked for by the last row appearing.
    public func loadMore() async {
        guard hasLoaded, isExhausted == false, isLoadingMore == false, phase == .ready else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await reads.notifications(after: cursor, limit: pageSize)
            let known = Set(rows.map(\.id))
            rows += page.items.filter { $0.isRenderable && known.contains($0.id) == false }
            cursor = page.nextCursor
            isExhausted = page.nextCursor == nil
        } catch {
            // The rows already shown stay; the next appearance of the last row asks again.
        }
    }

    private func load() async {
        if rows.isEmpty { phase = .loading }
        do {
            let page = try await reads.notifications(after: nil, limit: pageSize)
            rows = page.items.filter(\.isRenderable)
            cursor = page.nextCursor
            isExhausted = page.nextCursor == nil
            hasLoaded = true
            phase = .ready
        } catch {
            if rows.isEmpty { phase = .failed }
        }
        await refreshCount()
    }

    // MARK: - Actions

    /// The X: the row goes now, the tag stays. Back on a refusal.
    public func dismiss(_ row: AteNotification) async {
        guard inFlight.insert(row.id).inserted else { return }
        defer { inFlight.remove(row.id) }
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows.remove(at: index)
        if row.isUnread { unreadCount = max(0, unreadCount - 1) }
        analytics(NotificationEvents.notificationDismissed(how: .close))
        do {
            try await reads.dismiss(notificationID: row.id)
        } catch {
            rows.insert(row, at: min(index, rows.count))
            if row.isUnread { unreadCount += 1 }
        }
    }

    /// A tag was answered, declined, or found gone: its row leaves for good.
    public func finished(companionID: UUID) {
        let gone = rows.filter { $0.companionID == companionID }
        rows.removeAll { $0.companionID == companionID }
        let unread = gone.filter(\.isUnread).count
        unreadCount = max(0, unreadCount - unread)
    }

    /// Opening a tag marks it read on the server (`ate_with_prefill`): the bell follows at once.
    public func opened(companionID: UUID) {
        guard let index = rows.firstIndex(where: { $0.companionID == companionID }), rows[index].isUnread else {
            return
        }
        rows[index] = rows[index].read()
        unreadCount = max(0, unreadCount - 1)
    }

    public func row(companionID: UUID) -> AteNotification? {
        rows.first { $0.companionID == companionID }
    }
}
