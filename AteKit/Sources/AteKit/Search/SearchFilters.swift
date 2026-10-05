import Foundation
import Supabase

/// **What the Search tab narrows a typed search to** — cuisine, dietary tag and a minimum score
/// (round 4 search-filter contract): `search_places` and `search_dishes` take `p_cuisines text[]`,
/// `p_tags text[]` and `p_min_score numeric`, all optional, keyset paging unchanged.
///
/// A dish matches the tags when it carries all of them (its consensus tags); a place matches when
/// any one of its dishes does (backend #71). Search still needs two characters (`search_key`).
/// A minimum score leaves out anything nobody has scored — an empty score slot is not a number that
/// clears a bar (design rule 7). Filters apply to the Places and Dishes scopes only: a person has no
/// cuisine, and your own shelf is already yours.
public struct SearchFilters: Sendable, Hashable {
    /// Display strings as `search_cuisines()` returns them, in the order they were picked.
    public private(set) var cuisines: [String]
    /// Canonical order (gf, df, v, vg, nf) whatever order they were tapped in.
    public private(set) var tags: [DietTag]
    public var minimumScore: Double?
    /// The top of the score range (round 5); `nil` is open, so a 6 clears it.
    public var maximumScore: Double?
    /// The city a place is in (round 5). A display string until the backend's city contract lands.
    public var city: String?
    /// The months the lines were eaten in (round 6, 0050): a windowed search counts only those lines,
    /// so its numbers are the window's. On Saved, the day the dish was saved.
    public var window: DateWindow = .all

    public init(
        cuisines: [String] = [],
        tags: [DietTag] = [],
        minimumScore: Double? = nil,
        maximumScore: Double? = nil,
        city: String? = nil,
        window: DateWindow = .all
    ) {
        var seen = Set<String>()
        self.cuisines = cuisines.filter { seen.insert($0.lowercased()).inserted }
        self.tags = DietTag.allCases.filter(tags.contains)
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.city = city
        self.window = window
    }

    /// The score range the two ends describe — what the range slider edits.
    public var band: ScoreBand {
        get { ScoreBand(minScore: minimumScore, maxScore: maximumScore) }
        set {
            minimumScore = newValue.minScore
            maximumScore = newValue.maxScore
        }
    }

    public static let none = SearchFilters()

    /// The bars a minimum score can be set at. "Any" is `nil`.
    public static let minimumScores: [Double] = [3.0, 3.5, 4.0, 4.5]

    public var isEmpty: Bool {
        cuisines.isEmpty && tags.isEmpty && minimumScore == nil && maximumScore == nil && city == nil
            && window.isAll
    }

    /// How many filters are on — what the single Filter pill counts.
    public var count: Int {
        cuisines.count + tags.count + (band.isAll ? 0 : 1) + (city == nil ? 0 : 1) + (window.isAll ? 0 : 1)
    }

    // MARK: - The tag rule (backend #71)

    /// A dish matches the tag filter when it carries **every** picked code.
    public func dishMatchesTags(_ dishTags: [DietTag]) -> Bool {
        Set(tags).isSubset(of: dishTags)
    }

    /// A place matches when **any one** of its dishes carries every picked code — not when its
    /// dishes carry them between them (a GF pasta and a V salad is not a GF-and-V dish).
    public func placeMatchesTags(dishTags: [[DietTag]]) -> Bool {
        tags.isEmpty || dishTags.contains(where: dishMatchesTags)
    }

    // MARK: - Changing them

    public func contains(cuisine: String) -> Bool {
        cuisines.contains { $0.caseInsensitiveCompare(cuisine) == .orderedSame }
    }

    public func toggling(cuisine: String) -> SearchFilters {
        var next = self
        if contains(cuisine: cuisine) {
            next.cuisines.removeAll { $0.caseInsensitiveCompare(cuisine) == .orderedSame }
        } else {
            next.cuisines.append(cuisine)
        }
        return next
    }

    public func toggling(tag: DietTag) -> SearchFilters {
        let toggled = tags.contains(tag) ? tags.filter { $0 != tag } : tags + [tag]
        return SearchFilters(cuisines: cuisines, tags: toggled, minimumScore: minimumScore)
    }

    public func clearingCuisines() -> SearchFilters {
        SearchFilters(tags: tags, minimumScore: minimumScore)
    }

    public func clearingTags() -> SearchFilters {
        SearchFilters(cuisines: cuisines, minimumScore: minimumScore)
    }

    // MARK: - What a pill prints

    /// "Italian", "Italian +2", or `nil` when no cuisine is picked (the pill says "Cuisine").
    public var cuisineSummary: String? {
        guard let first = cuisines.first else { return nil }
        return cuisines.count == 1 ? first : "\(first) +\(cuisines.count - 1)"
    }

    /// "GF V" — the codes as their chips print them, space-parted (never a " · ", design rule 2).
    public var tagSummary: String? {
        tags.isEmpty ? nil : tags.map(\.label).joined(separator: " ")
    }

    /// "4.0+", or `nil` for any score.
    public var scoreSummary: String? {
        maximumScore == nil ? minimumScore.map { "\(ScoreFormat.halfStep($0))+" } : band.title
    }

    // MARK: - The active pills (round 4: the same pills as the Journal)

    /// One active filter as a removable pill: each cuisine, each tag, and the minimum score.
    public struct Pill: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case cuisine(String)
            case tag(DietTag)
            case minimumScore
            case city
            case window
        }

        public let kind: Kind
        public let title: String

        public var id: String {
            switch kind {
            case .cuisine(let cuisine): "cuisine.\(cuisine.lowercased())"
            case .tag(let tag): "tag.\(tag.rawValue)"
            case .minimumScore: "minScore"
            case .city: "city"
            case .window: "window"
            }
        }
    }

    /// Cuisines in the order picked, tags in their canonical order, then the score — "Italian",
    /// "GF", "4.0+".
    public var pills: [Pill] {
        (city.map { [Pill(kind: .city, title: AteCity.displayName(for: $0))] } ?? [])
            + (window.title().map { [Pill(kind: .window, title: $0)] } ?? [])
            + cuisines.map { Pill(kind: .cuisine($0), title: $0) }
            + tags.map { Pill(kind: .tag($0), title: $0.label) }
            + (scoreSummary.map { [Pill(kind: .minimumScore, title: $0)] } ?? [])
    }

    /// The filters without the pill the reader took away.
    public func removing(_ pill: Pill) -> SearchFilters {
        switch pill.kind {
        case .cuisine(let cuisine):
            return contains(cuisine: cuisine) ? toggling(cuisine: cuisine) : self
        case .tag(let tag):
            return tags.contains(tag) ? toggling(tag: tag) : self
        case .minimumScore:
            var next = self
            next.band = .all
            return next
        case .city:
            var next = self
            next.city = nil
            return next
        case .window:
            var next = self
            next.window = .all
            return next
        }
    }

    // MARK: - The wire

    /// Only the filters that are on. Absent is "no filter" — and an unfiltered search is exactly
    /// the call it always was, so a project without the new parameters still answers it.
    var parameters: [String: AnyJSON] {
        var parameters: [String: AnyJSON] = [:]
        if cuisines.isEmpty == false { parameters["p_cuisines"] = .array(cuisines.map { .string($0) }) }
        if tags.isEmpty == false { parameters["p_tags"] = .array(tags.map { .string($0.rawValue) }) }
        if let minimumScore { parameters["p_min_score"] = .double(minimumScore) }
        // Round 5, pending the backend lane's contract: sent only when set, so every call the
        // live functions already answer is unchanged.
        if let maximumScore { parameters["p_max_score"] = .double(maximumScore) }
        if let city { parameters["p_city"] = .string(city) }
        parameters.merge(window.parameters()) { _, window in window }
        return parameters
    }
}

/// One row of `search_cuisines()`: a cuisine we hold places for, and how many.
public struct CuisineCount: Sendable, Hashable, Identifiable, Decodable {
    public let cuisine: String
    public let placeCount: Int

    public var id: String { cuisine.lowercased() }

    public init(cuisine: String, placeCount: Int) {
        self.cuisine = cuisine
        self.placeCount = placeCount
    }

    enum CodingKeys: String, CodingKey {
        case cuisine
        case placeCount = "place_count"
    }
}

/// The filtered reads, with an honest default for a reader that cannot filter: it answers the
/// unfiltered question when nothing is on, and nothing at all when something is — a filter it
/// cannot apply must never come back looking applied.
extension SearchReading {
    public func places(
        query: String, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int
    ) async throws -> SearchPage<PlaceResult> {
        guard filters.isEmpty else { return SearchPage(rows: [], next: nil) }
        return try await places(query: query, after: cursor, pageSize: pageSize)
    }

    public func dishes(
        query: String, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int
    ) async throws -> SearchPage<DishResult> {
        guard filters.isEmpty else { return SearchPage(rows: [], next: nil) }
        return try await dishes(query: query, after: cursor, pageSize: pageSize)
    }

    public func cuisines() async throws -> [CuisineCount] { [] }

    public func savedDishes(
        matching query: String?, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int
    ) async throws -> SearchPage<SavedDish> {
        guard filters.isEmpty else { return SearchPage(rows: [], next: nil) }
        return try await savedDishes(matching: query, after: cursor, pageSize: pageSize)
    }

    public func searchCities() async throws -> [AteCity] { [] }

    public func nearbyPlaces(
        origin: SearchOrigin, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int
    ) async throws -> SearchPage<PlaceResult> {
        guard filters.isEmpty else { return SearchPage(rows: [], next: nil) }
        return try await nearbyPlaces(origin: origin, after: cursor, pageSize: pageSize)
    }
}
