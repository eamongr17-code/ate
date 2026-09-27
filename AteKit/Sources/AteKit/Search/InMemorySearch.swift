#if DEBUG
import Foundation

/// **The Search tab in memory** — previews, the XCUITest drive, and a simulator run with no backend
/// at all (`-ate-preview-data`).
///
/// Derived from the seeded entries like the place and dish pages are (`InMemoryPlaceDishes`), never
/// held separately: the places, dishes and people it finds are the ones the feed is drawing, so a
/// search can never offer a dish whose page would be empty. Matching is the same substring rule
/// `search_all` uses (`ilike '%q%'`), ranked the way the RPC ranks it — a prefix match first, then
/// alphabetically, which is what `similarity()` gives for real queries.
///
/// Debug only, in both directions: the type does not exist in a Beta or Release binary.
extension InMemorySocialService: SearchReading {

    // Every read answers in one page: the seeded catalogue is a screenful, and a cursor into it
    // would be machinery with nothing to walk.

    public func nearbyPlaces(
        origin: SearchOrigin,
        after cursor: SearchCursor?,
        pageSize: Int
    ) async throws -> SearchPage<PlaceResult> {
        // No geometry in memory: "nearby" is the places the seeded entries happen at, in the order
        // they were written. The list is *ranked* by something and attaches nothing — which is the
        // only property of Nearby the rest of the app depends on (design rule 8).
        SearchPage(rows: cursor == nil ? Array(places().prefix(6)) : [], next: nil)
    }

    public func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult> {
        SearchPage(rows: cursor == nil ? places().filter { Self.matches($0.name, query) } : [], next: nil)
    }

    public func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<DishResult> {
        SearchPage(rows: cursor == nil ? dishResults().filter { Self.matches($0.name, query) } : [], next: nil)
    }

    public func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PersonResult> {
        let matches = peopleResults().filter { row in
            Self.matches(row.handle, query) || Self.matches(row.name ?? "", query)
        }
        return SearchPage(rows: cursor == nil ? matches : [], next: nil)
    }

    public func savedDishes(
        matching query: String?,
        after cursor: SearchCursor?,
        pageSize: Int
    ) async throws -> SearchPage<SavedDish> {
        guard cursor == nil else { return SearchPage(rows: [], next: nil) }
        let shelf = try await savedDishesPage(after: nil, pageSize: PageRequest.maximumLimit).items
        guard let query, query.isEmpty == false else { return SearchPage(rows: shelf, next: nil) }
        // Dish OR place, like `search_saved`.
        return SearchPage(
            rows: shelf.filter { Self.matches($0.dishName, query) || Self.matches($0.restaurantName, query) },
            next: nil
        )
    }

    // MARK: - Filters (the round 4 contract, answered from the seed)

    public func places(query: String, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int)
        async throws -> SearchPage<PlaceResult> {
        let rows = try await places(query: query, after: cursor, pageSize: pageSize).rows
        let lines = visibleEntriesEverywhere()
        let menu = dishResults()
        let kept = rows.filter { place in
            let located = lines.first { $0.place?.id == place.restaurantID }?.place
            let dishTags = menu.filter { $0.restaurantID == place.restaurantID }.map(\.tags)
            return Self.passes(filters, cuisine: located?.cuisine, city: located?.city, score: place.score)
                && filters.placeMatchesTags(dishTags: dishTags)
        }
        return SearchPage(rows: kept, next: nil)
    }

    public func dishes(query: String, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int)
        async throws -> SearchPage<DishResult> {
        let rows = try await dishes(query: query, after: cursor, pageSize: pageSize).rows
        let places = Dictionary(
            visibleEntriesEverywhere().compactMap { entry in entry.place.map { ($0.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let kept = rows.filter { dish in
            Self.passes(
                filters, cuisine: places[dish.restaurantID]?.cuisine, city: places[dish.restaurantID]?.city,
                score: dish.score
            )
                && filters.dishMatchesTags(dish.tags)
        }
        return SearchPage(rows: kept, next: nil)
    }

    public func searchCities() async throws -> [AteCity] {
        var seen = Set<UUID>()
        let places = visibleEntriesEverywhere().compactMap(\.place).filter { seen.insert($0.id).inserted }
        return AteCity.counted(places.map(\.city))
    }

    public func savedDishes(
        matching query: String?, filters: SearchFilters, after cursor: SearchCursor?, pageSize: Int
    ) async throws -> SearchPage<SavedDish> {
        let page = try await savedDishes(matching: query, after: cursor, pageSize: pageSize)
        let filter = SavedDishFilter(band: filters.band, city: filters.city)
        return SearchPage(rows: page.rows.filter(filter.matches), next: page.next)
    }

    public func cuisines() async throws -> [CuisineCount] {
        var counts: [String: Set<UUID>] = [:]
        for place in visibleEntriesEverywhere().compactMap(\.place) {
            guard let cuisine = place.cuisine, cuisine.isEmpty == false else { continue }
            counts[cuisine, default: []].insert(place.id)
        }
        return counts
            .map { CuisineCount(cuisine: $0.key, placeCount: $0.value.count) }
            .sorted { ($0.placeCount, $1.cuisine) > ($1.placeCount, $0.cuisine) }
    }

    /// The contract's other two rules: any picked cuisine, and a scored-at-least bar that an unscored
    /// row never clears. Tags are ``SearchFilters``' own rule (every code, on one dish).
    private static func passes(_ filters: SearchFilters, cuisine: String?, city: String?, score: Double?) -> Bool {
        if let wanted = filters.city, AteCity.slug(for: city) != wanted { return false }
        if filters.cuisines.isEmpty == false {
            guard let cuisine, filters.contains(cuisine: cuisine) else { return false }
        }
        return filters.band.contains(score)
    }

    /// `search_key`'s rule: case- and accent-insensitive substring — "ragu" finds "ragù".
    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Derived from the seeded entries

    private func places() -> [PlaceResult] {
        var seen = Set<UUID>()
        var rows: [PlaceResult] = []
        for entry in visibleEntriesEverywhere() {
            guard let place = entry.place, seen.insert(place.id).inserted else { continue }
            let scores = visibleEntriesEverywhere()
                .filter { $0.place?.id == place.id }
                .flatMap(\.items)
                .compactMap(\.score?.value)
            rows.append(PlaceResult(
                restaurantID: place.id,
                name: place.name,
                // The seeded places carry bare suburbs, which is what `locality` is on the wire.
                locality: place.city.flatMap { $0.isEmpty ? nil : $0 },
                score: scores.isEmpty ? nil : (scores.reduce(0, +) / Double(scores.count) * 10).rounded() / 10
            ))
        }
        return rows
    }

    private func dishResults() -> [DishResult] {
        let lines = visibleEntriesEverywhere().flatMap { entry in entry.items.map { (entry, $0) } }
        return Dictionary(grouping: lines) { $0.1.dishID }.values.compactMap { rows -> DishResult? in
            guard let first = rows.first, let place = first.0.place else { return nil }
            let scores = rows.compactMap { $0.1.score?.value }
            return DishResult(
                dishID: first.1.dishID,
                name: first.1.dishName,
                restaurantID: place.id,
                restaurantName: place.name,
                score: scores.isEmpty ? nil : (scores.reduce(0, +) / Double(scores.count) * 10).rounded() / 10,
                coverURLString: rows.compactMap { $0.0.photos.first?.url }.first,
                peopleCount: Set(rows.map { $0.0.authorID }).count,
                tags: DishTagConsensus.tags(lines: rows.map { $0.1.tags })
            )
        }
        .sorted { $0.name < $1.name }
    }

    private func peopleResults() -> [PersonResult] {
        var seen = Set<UUID>()
        return visibleEntriesEverywhere().compactMap { entry -> PersonResult? in
            guard let author = entry.author, seen.insert(author.id).inserted else { return nil }
            return PersonResult(userID: author.id, handle: author.username, name: author.name)
        }
    }
}
#endif
