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

    public init(cuisines: [String] = [], tags: [DietTag] = [], minimumScore: Double? = nil) {
        var seen = Set<String>()
        self.cuisines = cuisines.filter { seen.insert($0.lowercased()).inserted }
        self.tags = DietTag.allCases.filter(tags.contains)
        self.minimumScore = minimumScore
    }

    public static let none = SearchFilters()

    /// The bars a minimum score can be set at. "Any" is `nil`.
    public static let minimumScores: [Double] = [3.0, 3.5, 4.0, 4.5]

    public var isEmpty: Bool { cuisines.isEmpty && tags.isEmpty && minimumScore == nil }

    /// How many filters are on — what the single Filter pill counts.
    public var count: Int { cuisines.count + tags.count + (minimumScore == nil ? 0 : 1) }

    public static func applies(to scope: SearchScope) -> Bool {
        scope == .places || scope == .dishes
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
        minimumScore.map { "\(ScoreFormat.halfStep($0))+" }
    }

    // MARK: - The wire

    /// Only the filters that are on. Absent is "no filter" — and an unfiltered search is exactly
    /// the call it always was, so a project without the new parameters still answers it.
    var parameters: [String: AnyJSON] {
        var parameters: [String: AnyJSON] = [:]
        if cuisines.isEmpty == false { parameters["p_cuisines"] = .array(cuisines.map { .string($0) }) }
        if tags.isEmpty == false { parameters["p_tags"] = .array(tags.map { .string($0.rawValue) }) }
        if let minimumScore { parameters["p_min_score"] = .double(minimumScore) }
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
}
