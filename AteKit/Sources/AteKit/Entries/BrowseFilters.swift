import Foundation

/// **What the Journal and Saved are narrowed to** (round 7: one chip per dimension): an order (the
/// Journal only), a score range, a city and a run of months. The range, the city and the months are
/// one choice shared by the two shelves; the order is the Journal's alone.
public struct BrowseFilters: Hashable, Sendable {
    public var sort: JournalSort
    public var band: ScoreBand
    /// A city slug, or `nil` for everywhere.
    public var city: String?
    public var window: DateWindow

    public init(sort: JournalSort = .newest, band: ScoreBand = .all, city: String? = nil, window: DateWindow = .all) {
        self.sort = sort
        self.band = band
        self.city = city
        self.window = window
    }

    /// The Journal's query for these filters — nothing else survives (no place, diet or period).
    public var journalQuery: JournalQuery {
        var query = JournalQuery(sort: sort, city: city, window: window)
        query.band = band
        return query
    }

    /// The Saved shelf's filter: the same range, city and months.
    public var savedFilter: SavedDishFilter {
        SavedDishFilter(band: band, city: city, window: window)
    }

    public init(_ query: JournalQuery) {
        self.init(sort: query.sort, band: query.band, city: query.city, window: query.window)
    }

    /// The filters with one chip's dimension put back to nothing.
    public func clearing(_ chip: BrowseChip) -> BrowseFilters {
        var next = self
        switch chip {
        case .sort: next.sort = .newest
        case .rating: next.band = .all
        case .city: next.city = nil
        case .date: next.window = .all
        }
        return next
    }

    /// Whether a chip's dimension is set — the chip goes ink with its value and an ✕.
    public func isActive(_ chip: BrowseChip) -> Bool {
        switch chip {
        case .sort: sort != .newest
        case .rating: band.isAll == false
        case .city: city != nil
        case .date: window.isAll == false
        }
    }

    /// What the chip says: its value when active ("4.0+", "Melbourne", "Mar–Aug 2026", "Top rated"),
    /// its own name when not.
    public func title(of chip: BrowseChip, cityName: String? = nil, now: Date = Date()) -> String {
        guard isActive(chip) else { return chip.name }
        switch chip {
        case .sort: return sort.title
        case .rating: return band.title ?? chip.name
        case .city: return cityName ?? city.map { AteCity.displayName(for: $0) } ?? chip.name
        case .date: return window.title(now: now) ?? chip.name
        }
    }
}

/// **One filter chip** under the header: Newest · Rating · City · Date. Each opens its own small
/// sheet. Saved has no order, so no sort chip.
public enum BrowseChip: String, CaseIterable, Sendable, Identifiable {
    case sort, rating, city, date

    public var id: String { rawValue }

    /// The chip's own name, at rest. The order's chip reads "Newest" — what the list is in.
    public var name: String {
        switch self {
        case .sort: JournalSort.newest.title
        case .rating: "Rating"
        case .city: "City"
        case .date: "Date"
        }
    }

    public enum Shelf: Sendable { case journal, saved }

    public static func chips(on shelf: Shelf) -> [BrowseChip] {
        switch shelf {
        case .journal: allCases
        case .saved: [.rating, .city, .date]
        }
    }
}
