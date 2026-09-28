import Foundation

/// **How the journal is ordered** — `my_entries(p_sort)`. Newest first is the journal as it has
/// always been; top is by the entry's best score, the unscored last.
public enum JournalSort: String, CaseIterable, Sendable, Hashable {
    case newest, oldest, top

    public var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .top: "Top rated"
        }
    }

    /// Month markers only mean something when the list runs through time.
    public var isChronological: Bool { self != .top }
}

/// A month or a whole year — the journal's date filter, sent as `p_from`/`p_to`.
public enum JournalPeriod: Hashable, Sendable {
    case month(year: Int, month: Int)
    case year(Int)

    /// The first and the last day the period covers, **both inclusive**, as the `date`s the
    /// contract takes. Calendar arithmetic, so a February or a leap year is never hand-counted.
    public func days(calendar: Calendar = .autoupdatingCurrent) -> (from: DateComponents, to: DateComponents) {
        switch self {
        case .year(let year):
            return (DateComponents(year: year, month: 1, day: 1), DateComponents(year: year, month: 12, day: 31))
        case .month(let year, let month):
            let first = DateComponents(year: year, month: month, day: 1)
            let length = calendar.date(from: first)
                .flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 31
            return (first, DateComponents(year: year, month: month, day: length))
        }
    }

    /// Whether a moment falls inside the period, in the reader's own calendar.
    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.year, .month], from: date)
        switch self {
        case .year(let year): return parts.year == year
        case .month(let year, let month): return parts.year == year && parts.month == month
        }
    }

    /// The period a moment is in, at month grain — what a month marker prints.
    public static func month(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> JournalPeriod {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    /// "September 2026", "2026". The month's name comes from the reader's locale.
    public func title(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch self {
        case .year(let year):
            return String(year)
        case .month(let year, let month):
            var calendar = calendar
            calendar.locale = locale
            let symbols = calendar.standaloneMonthSymbols
            let name = symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
            return "\(name) \(year)"
        }
    }
}

/// A place you have written at — `my_entry_places()`, the place filter's choices.
public struct JournalPlace: Sendable, Hashable, Identifiable, Codable {
    public let restaurantID: UUID
    public let name: String
    public let locality: String?
    public let entryCount: Int

    public var id: UUID { restaurantID }

    public init(restaurantID: UUID, name: String, locality: String? = nil, entryCount: Int = 0) {
        self.restaurantID = restaurantID
        self.name = name
        self.locality = locality
        self.entryCount = entryCount
    }

    enum CodingKeys: String, CodingKey {
        case name, locality
        case restaurantID = "restaurant_id"
        case entryCount = "entry_count"
    }
}

/// **What the journal is showing**: an order and up to four filters. The default is the journal
/// itself — newest first, everything — and reads the plain journal path, not `my_entries`.
public struct JournalQuery: Hashable, Sendable {
    public var sort: JournalSort
    public var place: JournalPlace?
    /// Entries whose best score is at least this. Half-point steps, like every score.
    public var minScore: Double?
    public var tag: DietTag?
    public var period: JournalPeriod?
    /// The top of the score range (round 5). `nil` is open — a 6 clears "5.0 and up".
    public var maxScore: Double?
    /// The city the entries were eaten in (round 5: a place is filtered by city, never by
    /// restaurant). A display string until the backend's city contract lands.
    public var city: String?
    /// The months the entries were eaten in (round 6) — the visit day, `p_from` / `p_to`.
    public var window: DateWindow = .all

    public init(
        sort: JournalSort = .newest,
        place: JournalPlace? = nil,
        minScore: Double? = nil,
        tag: DietTag? = nil,
        period: JournalPeriod? = nil,
        maxScore: Double? = nil,
        city: String? = nil,
        window: DateWindow = .all
    ) {
        self.sort = sort
        self.place = place
        self.minScore = minScore
        self.tag = tag
        self.period = period
        self.maxScore = maxScore
        self.city = city
        self.window = window
    }

    /// The score range the two ends describe — what the range slider edits.
    public var band: ScoreBand {
        get { ScoreBand(minScore: minScore, maxScore: maxScore) }
        set {
            minScore = newValue.minScore
            maxScore = newValue.maxScore
        }
    }

    /// The minimum-score choices the filter offers: whole stars, the way a person thinks about them.
    public static let minScoreSteps: [Double] = [3, 4, 5]

    public var hasFilters: Bool {
        place != nil || minScore != nil || maxScore != nil || tag != nil || period != nil || city != nil
            || window.isAll == false
    }
    public var isDefault: Bool { sort == .newest && hasFilters == false }

    /// The active filters, as the removable pills under the segment draw them, in a fixed order.
    public var pills: [JournalQueryPill] {
        var pills: [JournalQueryPill] = []
        if sort != .newest { pills.append(.sort(sort)) }
        if let city { pills.append(.city(city)) }
        if window.isAll == false { pills.append(.window(window)) }
        if let place { pills.append(.place(place)) }
        if maxScore != nil {
            pills.append(.band(band))
        } else if let minScore {
            pills.append(.minScore(minScore))
        }
        if let tag { pills.append(.tag(tag)) }
        if let period { pills.append(.period(period)) }
        return pills
    }

    /// The same query without one pill. Removing the order pill returns to newest first.
    public func removing(_ pill: JournalQueryPill) -> JournalQuery {
        var next = self
        switch pill {
        case .sort: next.sort = .newest
        case .place: next.place = nil
        case .minScore: next.minScore = nil
        case .band: next.band = .all
        case .city: next.city = nil
        case .window: next.window = .all
        case .tag: next.tag = nil
        case .period: next.period = nil
        }
        return next
    }

    /// Whether an entry belongs in this query's list — what the in-memory journal filters by, and
    /// whether a freshly written entry may be put at the top of a filtered list.
    public func matches(_ card: EntryCard, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        if let place, card.restaurantID != place.restaurantID { return false }
        // The range's own rule: no bound is everything, any bound leaves the unscored out.
        if band.contains(card.bestScore) == false { return false }
        if let city, AteCity.slug(for: card.place?.city) != city { return false }
        if window.contains(card.createdAt, calendar: calendar) == false { return false }
        if let tag, card.items.contains(where: { $0.tags.contains(tag) }) == false { return false }
        if let period, period.contains(card.createdAt, calendar: calendar) == false { return false }
        return true
    }

    /// Orders cards the way `my_entries(p_sort)` does: time with an id tiebreak, or best score
    /// (unscored last), then newest, then id.
    public func ordered(_ cards: [EntryCard]) -> [EntryCard] {
        cards.sorted { lhs, rhs in
            switch sort {
            case .newest:
                return (lhs.createdAt, lhs.id.uuidString) > (rhs.createdAt, rhs.id.uuidString)
            case .oldest:
                return (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
            case .top:
                let left = lhs.bestScore ?? -1
                let right = rhs.bestScore ?? -1
                if left != right { return left > right }
                return (lhs.createdAt, lhs.id.uuidString) > (rhs.createdAt, rhs.id.uuidString)
            }
        }
    }

    /// Telemetry's spelling of the filters in use: `place,min_score` — names only, never values.
    public var filterNames: String {
        var names: [String] = []
        if place != nil { names.append("place") }
        if minScore != nil { names.append("min_score") }
        if maxScore != nil { names.append("max_score") }
        if city != nil { names.append("city") }
        if window.isAll == false { names.append("window") }
        if tag != nil { names.append("tag") }
        if period != nil { names.append("period") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

/// One active filter, drawn as a removable pill.
public enum JournalQueryPill: Hashable, Sendable, Identifiable {
    case sort(JournalSort)
    case place(JournalPlace)
    case minScore(Double)
    case band(ScoreBand)
    case city(String)
    case window(DateWindow)
    case tag(DietTag)
    case period(JournalPeriod)

    public var id: String {
        switch self {
        case .sort: "sort"
        case .place: "place"
        case .minScore: "minScore"
        case .band: "score"
        case .city: "city"
        case .window: "window"
        case .tag: "tag"
        case .period: "period"
        }
    }

    /// What the pill says. A score reads like a price, one decimal and a plus: "4.0+".
    public var title: String {
        switch self {
        case .sort(let sort): sort.title
        case .place(let place): place.name
        case .minScore(let score): ScoreFormat.halfStep(score) + "+"
        case .band(let band): band.title ?? ""
        case .city(let city): AteCity.displayName(for: city)
        case .window(let window): window.title() ?? ""
        case .tag(let tag): tag.label
        case .period(let period): period.title()
        }
    }
}

public extension EntryCard {
    /// The entry's best score — what `top` sorts by and the minimum-score filter reads. `nil` when
    /// nothing on it was scored: an unscored entry is never a zero.
    var bestScore: Double? { items.compactMap(\.score?.value).max() }
}

/// **Where the next page of a queried journal starts.** The composite key follows the order: a
/// time-ordered list pages on `(created_at, id)`; a top-rated one on `(best score, created_at, id)`.
public struct JournalCursor: Sendable, Hashable {
    public let createdAt: Date
    public let id: UUID
    /// The last row's best score, when the order is by score. `nil` there means the last row was
    /// unscored — the tail of the list.
    public let score: Double?

    public init(createdAt: Date, id: UUID, score: Double? = nil) {
        self.createdAt = createdAt
        self.id = id
        self.score = score
    }

    public init(after card: EntryCard) {
        self.init(createdAt: card.createdAt, id: card.id, score: card.bestScore)
    }

    public var pageCursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }
}

/// One page of a queried journal.
public struct JournalQueryPage: Sendable {
    public let items: [EntryCard]
    public let nextCursor: JournalCursor?

    public init(items: [EntryCard], nextCursor: JournalCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// A short read is the last page — the same inference every keyset list here makes.
    public init(items: [EntryCard], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last.map(JournalCursor.init(after:))
    }
}

/// **The journal's filter and sort reads** (round 4 contract): `my_entries` for the ordered ids,
/// `entry_cards` for the rows, and `my_entry_places` for the place filter's choices.
public protocol JournalQuerying: Sendable {
    func myEntries(
        _ query: JournalQuery,
        after cursor: JournalCursor?,
        pageSize: Int
    ) async throws -> JournalQueryPage
    func myEntryPlaces() async throws -> [JournalPlace]
    /// `my_entry_cities()` (0047) — the cities your own entries are in, busiest first: the filter's
    /// City choices.
    func myEntryCities() async throws -> [AteCity]
}

public extension JournalQuerying {
    /// A reader without `my_entry_cities` offers no cities — the filter shows Everywhere alone.
    func myEntryCities() async throws -> [AteCity] { [] }
}
