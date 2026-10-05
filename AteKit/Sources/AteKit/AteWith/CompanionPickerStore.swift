import Foundation
import Observation

/// **"Who were you with?", as state.** Before typing: the people tagged most recently. Typing two
/// characters or more searches every handle on Ate, debounced, the last query winning. Rows toggle;
/// the picked gather as chips; six at most (the server's seats).
///
/// The viewer never appears, and nobody blocked either way does — the server leaves them out of
/// both reads, and the store does not second-guess it.
@MainActor
@Observable
public final class CompanionPickerStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    /// Six people an entry (`tag_ate_with`'s `ate_with_cap`).
    public nonisolated static let cap = 6
    /// `search_people` matches nothing under two characters.
    public nonisolated static let minimumQuery = 2

    /// What is in the field. Setting it schedules a search; it never searches on the keystroke.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            schedule()
        }
    }

    public private(set) var selected: [CompanionPerson]
    public private(set) var recents: [CompanionPerson] = []
    public private(set) var results: [CompanionPerson] = []
    public private(set) var phase: Phase = .loading
    public private(set) var hasMore = false

    /// Who the sheet opened holding — what the commit pill compares against.
    public let initial: [CompanionPerson]

    @ObservationIgnored private let service: any CompanionTagging
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var next: SearchCursor?
    @ObservationIgnored private var generation = 0

    public init(
        service: any CompanionTagging,
        selected: [CompanionPerson] = [],
        debounce: Duration = .milliseconds(250),
        pageSize: Int = 20
    ) {
        let capped = Array(selected.prefix(Self.cap))
        self.service = service
        self.selected = capped
        self.initial = capped
        self.debounce = debounce
        self.pageSize = pageSize
    }

    // MARK: - What the sheet draws

    /// The trimmed query, and whether it is long enough to go to the server.
    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isSearching: Bool { typed.count >= Self.minimumQuery }

    /// The list under the field. Before typing: whoever is picked and not a recent, then the
    /// recents — so an edit's people can be unticked. One character filters that list locally.
    public var rows: [CompanionPerson] {
        if isSearching { return results }
        let recentIDs = Set(recents.map(\.userID))
        let standing = selected.filter { recentIDs.contains($0.userID) == false } + recents
        return standing.filter { $0.matches(typed) }
    }

    public func isSelected(_ person: CompanionPerson) -> Bool {
        selected.contains { $0.userID == person.userID }
    }

    public var isFull: Bool { selected.count >= Self.cap }

    /// The foot pill: "Add @jess", "Add 2 people" — or, with everyone unticked from an entry that had
    /// people, "Remove @jess". `nil` title is never returned; ``canCommit`` says whether it is live.
    public var commitTitle: String {
        if selected.isEmpty, initial.isEmpty == false {
            return initial.count == 1 ? "Remove @\(initial[0].handle)" : "Remove \(initial.count) people"
        }
        switch selected.count {
        case 0: return "Add people"
        case 1: return "Add @\(selected[0].handle)"
        default: return "Add \(selected.count) people"
        }
    }

    /// Live once there is something to apply: anyone picked, or a change from what it opened with.
    public var canCommit: Bool {
        selected.isEmpty == false || initial.isEmpty == false
    }

    // MARK: - Actions

    /// Ticks or unticks a row. Returns `false` when a seventh is refused — the caller says so with a
    /// haptic, never with copy.
    @discardableResult
    public func toggle(_ person: CompanionPerson) -> Bool {
        if let index = selected.firstIndex(where: { $0.userID == person.userID }) {
            selected.remove(at: index)
            return true
        }
        guard isFull == false else { return false }
        selected.append(person)
        return true
    }

    /// A chip's ✕.
    public func remove(_ person: CompanionPerson) {
        selected.removeAll { $0.userID == person.userID }
    }

    /// The standing list, as the sheet rises.
    public func loadRecents() async {
        do {
            recents = try await service.recentCompanions(limit: Self.recentLimit)
            if isSearching == false { phase = .ready }
        } catch {
            if isSearching == false { phase = recents.isEmpty ? .failed : .ready }
        }
    }

    /// The next page of a search, at the foot of the list.
    public func loadMore() async {
        guard isSearching, hasMore, let cursor = next else { return }
        let query = typed
        let generationAtStart = generation
        guard let page = try? await service.searchPeople(query, after: cursor, pageSize: pageSize),
              generationAtStart == generation else { return }
        results += page.rows.filter { row in results.contains { $0.userID == row.userID } == false }
        next = page.next
        hasMore = page.next != nil
    }

    /// Runs the current query now — what the debounce ends in, and what a test calls directly.
    public func search() async {
        generation += 1
        let generationAtStart = generation
        guard isSearching else {
            results = []
            next = nil
            hasMore = false
            phase = .ready
            return
        }
        phase = .loading
        let query = typed
        do {
            let page = try await service.searchPeople(query, after: nil, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            results = page.rows
            next = page.next
            hasMore = page.next != nil
            phase = .ready
        } catch {
            guard generationAtStart == generation else { return }
            phase = .failed
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard Task.isCancelled == false else { return }
            await self?.search()
        }
    }

    /// How many recent people the list opens on.
    static let recentLimit = 8
}
