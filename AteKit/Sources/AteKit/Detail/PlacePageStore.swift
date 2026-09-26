import Foundation
import Observation

/// **The place page**: the header, "what to order", the viewer's own visits, and everybody else's.
///
/// Four reads that fail independently, because they fail independently in life: a place whose menu
/// has not been written about yet is a real, drawable page, and a header that 404s must not take a
/// loaded list down with it. The two entry lists are ``EntryListStore``s — the same keyset paging,
/// dedup and save-broadcast behaviour the feed and a profile already have, pointed at
/// `get_entries_at_place` with a different scope.
@MainActor
@Observable
public final class PlacePageStore {

    public enum Header: Sendable, Equatable {
        case loading
        case ready(PlaceSummary)
        /// Deleted, never there, or behind a block. Every read tolerates a missing row (contract).
        case unavailable
        /// The read never came back — offline, or the server fell over. Not the same as a place
        /// that is not there: this one is worth another try, and the page offers one.
        case unreachable

        /// Either way the page has said all it will: its one line, and nothing under it.
        public var isFailure: Bool { self == .unavailable || self == .unreachable }
    }

    /// Where "what to order" has got to. Its own state: an empty menu is not an error and must not
    /// read as one.
    public enum Menu: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    /// One page of the menu. A real place fits in the first (`place_dishes` clamps at 200); the
    /// cursor exists so a pathological one walks rather than stopping silently.
    public static let menuPageSize = PlacePageClient.maximumDishes

    public let restaurantID: UUID
    public let source: DetailSource

    public private(set) var header: Header = .loading
    public private(set) var menu: Menu = .loading
    /// The menu, in the order the server sends it — which is ``DishRanking``'s (0030). Not sorted
    /// here, and it must not start being: see ``MenuDishCursor``.
    public private(set) var dishes: [MenuDish] = []
    /// The viewer's own entries here — "Your N visits".
    public let visits: EntryListStore
    /// Everybody else's, newest first.
    public let entries: EntryListStore

    private let places: any PlacePageReading
    private let analytics: AnalyticsRecorder
    private var hasLoadedHeader = false
    private var hasRecordedView = false
    private var nextMenuCursor: MenuDishCursor?
    private var seenDishIDs: Set<UUID> = []
    private var isLoadingMenu = false
    private let menuPageSize: Int

    public init(
        restaurantID: UUID,
        source: DetailSource = .unknown,
        places: any PlacePageReading,
        pageSize: Int = 20,
        menuPageSize: Int = PlacePageStore.menuPageSize,
        savedDishes: SavedDishBroadcast? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.restaurantID = restaurantID
        self.source = source
        self.places = places
        self.menuPageSize = menuPageSize
        self.analytics = analytics
        self.visits = EntryListStore(
            pageSize: pageSize,
            fallbackMessage: "Couldn't load your visits.",
            savedDishes: savedDishes
        ) { [places] cursor, size in
            try await places.entriesAtPlace(
                restaurantID: restaurantID, scope: .mine, after: cursor, pageSize: size
            )
        }
        self.entries = EntryListStore(
            pageSize: pageSize,
            fallbackMessage: "Couldn't load these entries.",
            savedDishes: savedDishes
        ) { [places] cursor, size in
            try await places.entriesAtPlace(
                restaurantID: restaurantID, scope: .others, after: cursor, pageSize: size
            )
        }
    }

    // MARK: - What the view reads

    public var summary: PlaceSummary? {
        if case .ready(let summary) = header { return summary }
        return nil
    }

    public var name: String? { summary?.name }

    /// The header's chips, in the artboard's order: the average, how many people, the cuisine, the
    /// suburb. Built here rather than in the view so "a chip is only drawn when we actually have
    /// the fact" is one rule in one place (design rule 8 — nothing is ever assumed).
    public var facts: [PlaceFact] {
        guard let summary else { return [] }
        var facts: [PlaceFact] = []
        if let rating = summary.avgRating { facts.append(.rating(ScoreFormat.average(rating))) }
        if summary.peopleCount > 0 { facts.append(.people(summary.peopleCount.formatted())) }
        if let cuisine = summary.cuisine, cuisine.isEmpty == false { facts.append(.word(cuisine)) }
        // The SUBURB, and only ever `locality`: `city` on a live Google row is a mangled slice of
        // the formatted address, and a chip is a fact or it is nothing (0029, design rule 8).
        if let locality = summary.locality, locality.isEmpty == false { facts.append(.word(locality)) }
        return facts
    }

    /// "Your 3 visits" — the band is absent at zero rather than saying "no visits".
    public var myVisits: Int { summary?.myVisits ?? 0 }
    public var hasVisits: Bool { myVisits > 0 }

    // MARK: - Loading

    public func load() async {
        async let header: Void = loadHeaderIfNeeded()
        async let dishes: Void = loadMenuIfNeeded()
        async let mine: Void = visits.loadIfNeeded()
        async let theirs: Void = entries.loadIfNeeded()
        _ = await (header, dishes, mine, theirs)
    }

    public func refresh() async {
        hasLoadedHeader = false
        async let header: Void = loadHeaderIfNeeded()
        async let dishes: Void = loadMenu()
        async let mine: Void = visits.refresh()
        async let theirs: Void = entries.refresh()
        _ = await (header, dishes, mine, theirs)
    }

    /// "Try again", after a header that never came back. The same reads a pull to refresh makes,
    /// with the header back to its skeleton while they are in the air.
    public func retry() async {
        guard header == .unreachable else { return }
        analytics(RecoveryEvents.detailRetried(.place))
        header = .loading
        await refresh()
    }

    /// Only a row the server said is not there is "not here". Everything else — a timeout, a 500,
    /// no network — is "couldn't reach Ate", and gets a retry.
    private static func isMissing(_ error: AteAPIError) -> Bool {
        if case .notFound = error { return true }
        return false
    }

    private func loadHeaderIfNeeded() async {
        guard hasLoadedHeader == false else { return }
        do {
            let summary = try await places.placeSummary(restaurantID: restaurantID)
            hasLoadedHeader = true
            header = .ready(summary)
            recordViewIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            hasLoadedHeader = true
            let isMissing = (error as? AteAPIError).map(Self.isMissing) == true
            header = isMissing ? .unavailable : .unreachable
            if isMissing == false { analytics(RecoveryEvents.detailUnreachable(.place)) }
        }
    }

    private func loadMenuIfNeeded() async {
        guard menu == .loading else { return }
        await loadMenu()
    }

    private func loadMenu() async {
        guard isLoadingMenu == false else { return }
        isLoadingMenu = true
        defer { isLoadingMenu = false }
        do {
            let page = try await places.placeDishes(
                restaurantID: restaurantID, after: nil, pageSize: menuPageSize
            )
            dishes = []
            seenDishIDs = []
            append(page)
            menu = .ready
        } catch is CancellationError {
            return
        } catch {
            menu = .failed
        }
    }

    /// The next page of the menu, cut with the four-part keyset. Fires as the last rows appear.
    public func loadMoreDishesIfNeeded(after dish: MenuDish) async {
        guard let index = dishes.firstIndex(where: { $0.id == dish.id }),
              index >= dishes.count - 3 else { return }
        await loadMoreDishes()
    }

    public func loadMoreDishes() async {
        guard isLoadingMenu == false, let cursor = nextMenuCursor else { return }
        isLoadingMenu = true
        defer { isLoadingMenu = false }
        do {
            append(try await places.placeDishes(
                restaurantID: restaurantID, after: cursor, pageSize: menuPageSize
            ))
        } catch is CancellationError {
            return
        } catch {
            // A later page that falls over must not blank a menu that is already readable; it just
            // stops paging.
            nextMenuCursor = nil
        }
    }

    /// Appends, dropping ids already on screen — a duplicate id in a SwiftUI list is a crash, not a
    /// cosmetic bug. **No re-sort:** the order arrived correct (see ``MenuDishCursor``).
    private func append(_ page: MenuDishPage) {
        dishes.append(contentsOf: page.items.filter { seenDishIDs.insert($0.dishID).inserted })
        nextMenuCursor = page.nextCursor
    }

    // MARK: - Funnel

    /// Fired once per screen, after the header resolves — so the funnel counts places people
    /// actually saw, not failed loads.
    private func recordViewIfNeeded() {
        guard hasRecordedView == false else { return }
        hasRecordedView = true
        analytics(DetailEvents.restaurantDetailViewed(restaurantID: restaurantID, source: source))
    }
}

/// One chip in the place header. A closed set, because each one is drawn differently — the average
/// carries a star, the people count carries the people mark, and a cuisine or a suburb is a bare
/// word.
public enum PlaceFact: Sendable, Hashable, Identifiable {
    case rating(String)
    case people(String)
    case word(String)

    public var id: String {
        switch self {
        case .rating(let value): "rating:\(value)"
        case .people(let value): "people:\(value)"
        case .word(let value): "word:\(value)"
        }
    }

    public var text: String {
        switch self {
        case .rating(let value), .people(let value), .word(let value): value
        }
    }
}
