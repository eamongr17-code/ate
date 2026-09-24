#if DEBUG
import Foundation

/// **The place and dish pages in memory** — previews and a simulator run with no backend at all
/// (`-ate-preview-data`).
///
/// Everything here is *derived from the seeded entries*, never held separately: the aggregates the
/// server computes in `restaurant_stats` / `dish_stats` are recomputed from the same rows the feed
/// is drawing, so a dish saved or written in a preview drive shows up on its page immediately and
/// the two can never disagree about what happened.
///
/// Debug only, in both directions — the type does not exist in a Beta or Release binary.
extension InMemorySocialService: PlacePageReading, DishPageReading {

    // MARK: - Place

    public func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
        let visible = try visibleEntries(atPlace: restaurantID)
        guard let place = visible.compactMap(\.place).first else {
            throw AteAPIError.notFound(table: "restaurants", id: restaurantID)
        }
        let items = visible.flatMap(\.items)
        // The mean of per-dish averages, exactly as `restaurant_stats` defines it (data-model
        // §1.2) — not the mean of every review, which is a different and wrong number.
        let perDish = Dictionary(grouping: items, by: \.dishID).values
            .compactMap { lines -> Double? in
                let scores = lines.compactMap(\.score?.value)
                guard scores.isEmpty == false else { return nil }
                return scores.reduce(0, +) / Double(scores.count)
            }
        return PlaceSummary(
            restaurantID: restaurantID,
            name: place.name,
            address: place.address,
            locality: place.city,
            city: place.city,
            cuisine: place.cuisine,
            coverURLString: visible.compactMap { $0.photos.first?.url }.first,
            avgRating: perDish.isEmpty ? nil : (perDish.reduce(0, +) / Double(perDish.count)).rounded(toPlaces: 1),
            reviewCount: items.count,
            entryCount: visible.count,
            peopleCount: Set(visible.map(\.authorID)).count,
            dishCount: Set(items.map(\.dishID)).count,
            myVisits: visible.filter(\.isMine).count,
            myLastVisit: visible.filter(\.isMine).map(\.createdAt).max()
        )
    }

    public func placeDishes(
        restaurantID: UUID,
        after cursor: MenuDishCursor?,
        pageSize: Int
    ) async throws -> MenuDishPage {
        let visible = try visibleEntries(atPlace: restaurantID)
        let lines = visible.flatMap { entry in entry.items.map { (entry: entry, item: $0) } }
        let byDish = Dictionary(grouping: lines) { $0.item.dishID }
        let dishes = byDish.compactMap { dishID, rows -> MenuDish? in
            guard let first = rows.first else { return nil }
            let scores = rows.compactMap(\.item.score?.value)
            return MenuDish(
                dishID: dishID,
                name: first.item.dishName,
                score: scores.isEmpty ? nil : (scores.reduce(0, +) / Double(scores.count)).rounded(toPlaces: 1),
                peopleCount: Set(rows.map(\.entry.authorID)).count,
                reviewCount: rows.count,
                coverURLString: rows.compactMap { $0.entry.photos.first?.url }.first
            )
        }
        // The server's own order since 0030 — which is DishRanking's rule, so the pure type that
        // states it is the one that sorts here too. A dish nobody has reviewed is not on the menu.
        let ordered = DishRanking.rank(dishes.filter { $0.reviewCount > 0 })
        let remaining = cursor.map { cursor in
            Array(ordered.drop { $0.dishID != cursor.dishID }.dropFirst())
        } ?? ordered
        return MenuDishPage(items: Array(remaining.prefix(max(1, pageSize))), requestedLimit: pageSize)
    }

    public func entriesAtPlace(
        restaurantID: UUID,
        scope: PlaceEntryScope,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        let rows = ((try? visibleEntries(atPlace: restaurantID)) ?? []).filter { entry in
            switch scope {
            case .all: true
            case .mine: entry.isMine
            case .others: entry.isMine == false
            }
        }
        let start = cursor.map { cursor in
            rows.filter { ($0.createdAt, $0.id.uuidString) < (cursor.createdAt, cursor.id.uuidString) }
        } ?? rows
        return Page(items: Array(start.prefix(pageSize)), requestedLimit: pageSize)
    }

    // MARK: - Dish

    public func dishSummary(dishID: UUID) async throws -> DishSummary {
        let lines = allLines().filter { $0.item.dishID == dishID }
        guard let first = lines.first, let place = first.entry.place else {
            throw AteAPIError.notFound(table: "dishes", id: dishID)
        }
        let scores = lines.compactMap(\.item.score?.value)
        return DishSummary(
            dishID: dishID,
            name: first.item.dishName,
            restaurantID: place.id,
            restaurantName: place.name,
            restaurantLocality: place.city,
            restaurantCity: place.city,
            score: scores.isEmpty ? nil : (scores.reduce(0, +) / Double(scores.count)).rounded(toPlaces: 1),
            reviewCount: lines.count,
            scoredCount: scores.count,
            peopleCount: Set(lines.map(\.entry.authorID)).count,
            coverURLString: lines.compactMap { $0.entry.photos.first?.url }.first,
            photos: lines.flatMap { line in
                line.entry.photos.map { DishPhoto(url: $0.url, entryID: line.entry.id) }
            },
            isSaved: first.item.saved,
            myLastScore: lines.filter(\.entry.isMine).compactMap(\.item.score?.value).first
        )
    }

    public func dishReviews(
        dishID: UUID,
        after cursor: DishReviewCursor?,
        pageSize: Int
    ) async throws -> DishReviewPage {
        let rows = allLines()
            .filter { $0.item.dishID == dishID }
            .map { line in
                DishReview(
                    reviewID: line.item.reviewID,
                    entryID: line.entry.id,
                    author: line.entry.author,
                    score: line.item.score,
                    note: line.item.note,
                    createdAt: line.entry.createdAt,
                    isMine: line.entry.isMine,
                    photos: line.entry.photos
                )
            }
            .sorted { Self.sortKey(for: $0) > Self.sortKey(for: $1) }
        let start = cursor.map { cursor in
            rows.filter { Self.sortKey(for: $0) < (cursor.isMine ? 1 : 0, cursor.createdAt, cursor.id.uuidString) }
        } ?? rows
        return DishReviewPage(items: Array(start.prefix(pageSize)), requestedLimit: pageSize)
    }

    public func isDishSaved(dishID: UUID) async throws -> Bool {
        allLines().first { $0.item.dishID == dishID }?.item.saved ?? false
    }

    // MARK: - Machinery

    // `(is_mine, created_at, id) DESC` — the order `get_dish_reviews` returns. Three members
    // because the server's keyset has three; collapsing it would be collapsing the contract.
    // swiftlint:disable:next large_tuple
    private static func sortKey(for review: DishReview) -> (Int, Date, String) {
        (review.isMine ? 1 : 0, review.createdAt, review.reviewID.uuidString)
    }

    private func visibleEntries(atPlace restaurantID: UUID) throws -> [EntryCard] {
        let rows = visibleEntriesEverywhere().filter { $0.place?.id == restaurantID }
        guard rows.isEmpty == false else {
            throw AteAPIError.notFound(table: "restaurants", id: restaurantID)
        }
        return rows
    }

    private func allLines() -> [(entry: EntryCard, item: EntryCard.Item)] {
        visibleEntriesEverywhere().flatMap { entry in
            entry.items.map { (entry: entry, item: $0) }
        }
    }
}

private extension Double {
    /// The server hands aggregates back at 1dp (`numeric(2,1)`); the in-memory stand-in does the
    /// same, so a preview and staging print the same number of digits.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
#endif
