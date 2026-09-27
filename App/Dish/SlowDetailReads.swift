#if DEBUG
import AteKit
import Foundation

/// **`-ate-slow-detail`** — the dish and place pages' reads held back, so a drive can see what the
/// page draws before they answer (round 6: it draws from the row that opened it, at once, and waits
/// in still shapes). Debug only; preview data answers instantly otherwise.
enum SlowDetailReads {
    static let argument = "-ate-slow-detail"
    static let delay: Duration = .seconds(2)

    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func dishes(_ reads: any DishPageReading) -> any DishPageReading {
        isOn ? SlowDishPages(reads: reads) : reads
    }

    static func places(_ reads: any PlacePageReading) -> any PlacePageReading {
        isOn ? SlowPlacePages(reads: reads) : reads
    }
}

private struct SlowDishPages: DishPageReading {
    let reads: any DishPageReading

    func dishSummary(dishID: UUID) async throws -> DishSummary {
        try await Task.sleep(for: SlowDetailReads.delay)
        return try await reads.dishSummary(dishID: dishID)
    }

    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage {
        try await Task.sleep(for: SlowDetailReads.delay)
        return try await reads.dishReviews(dishID: dishID, after: cursor, pageSize: pageSize)
    }

    func isDishSaved(dishID: UUID) async throws -> Bool {
        try await reads.isDishSaved(dishID: dishID)
    }
}

private struct SlowPlacePages: PlacePageReading {
    let reads: any PlacePageReading

    func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
        try await Task.sleep(for: SlowDetailReads.delay)
        return try await reads.placeSummary(restaurantID: restaurantID)
    }

    func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws -> MenuDishPage {
        try await Task.sleep(for: SlowDetailReads.delay)
        return try await reads.placeDishes(restaurantID: restaurantID, after: cursor, pageSize: pageSize)
    }

    func entriesAtPlace(
        restaurantID: UUID,
        scope: PlaceEntryScope,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        try await Task.sleep(for: SlowDetailReads.delay)
        return try await reads.entriesAtPlace(
            restaurantID: restaurantID, scope: scope, after: cursor, pageSize: pageSize
        )
    }
}
#endif
