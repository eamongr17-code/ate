import Foundation

/// **`Blocked people`** — the list, its cursor, and the one action on it.
///
/// Paginated from day one like every other list (ARCHITECTURE.md), even though most people will
/// never block more than a handful: the list that is small today is the one nobody remembers to
/// page tomorrow.
///
/// Unblocking removes the row **before** the RPC and puts it back on a refusal, the same shape as
/// the save action — a one-tap action on a list has to be felt immediately, and the only honest way
/// to do that is to be able to undo it.
@MainActor
@Observable
public final class BlockedPeopleStore {
    public private(set) var people: [BlockedPerson] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var didFail = false

    @ObservationIgnored private let account: any AccountServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor?
    @ObservationIgnored private var isExhausted = false
    /// Unblocks with a call in the air. A second tap on the same row is dropped rather than queued.
    @ObservationIgnored private var inFlight: Set<UUID> = []

    public init(
        account: any AccountServing,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = AccountClient.defaultPageSize
    ) {
        self.account = account
        self.analytics = analytics
        self.pageSize = pageSize
    }

    /// Nobody is blocked — the state the screen draws nothing for.
    public var isEmpty: Bool { hasLoaded && people.isEmpty }

    public func loadIfNeeded() async {
        guard hasLoaded == false, isLoading == false else { return }
        await load(reset: true)
    }

    public func refresh() async {
        await load(reset: true)
    }

    /// The next page, asked for by the last row appearing.
    public func loadMore() async {
        guard isExhausted == false, isLoading == false, hasLoaded else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        if reset {
            cursor = nil
            isExhausted = false
        }
        do {
            let page = try await account.blockedPeople(after: cursor, pageSize: pageSize)
            didFail = false
            if reset {
                people = page.items
            } else {
                // Keyset pages cannot overlap, but a refresh racing a page can — id-dedup rather
                // than trusting the cursor to be the only writer.
                let known = Set(people.map(\.id))
                people += page.items.filter { known.contains($0.id) == false }
            }
            cursor = page.nextCursor
            isExhausted = page.isLastPage
        } catch {
            didFail = true
            isExhausted = true
        }
    }

    /// Unblock. The row goes now; it comes back if the server says no.
    public func unblock(_ person: BlockedPerson) async {
        guard inFlight.insert(person.id).inserted else { return }
        defer { inFlight.remove(person.id) }
        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
        people.remove(at: index)
        analytics(AccountEvents.userUnblocked())
        do {
            try await account.unblock(userID: person.id)
        } catch {
            people.insert(person, at: min(index, people.count))
            didFail = true
        }
    }
}
