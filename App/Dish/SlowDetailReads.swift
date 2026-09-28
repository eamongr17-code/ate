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

/// **`-ate-profile-detail`** — how long a dish or place page takes to settle, measured in the app
/// (a UI test's own clock waits for the app to go idle, so it cannot see a page draw before its read
/// answers). One line per open, appended to `Documents/detail-timings.txt` for a drive to collect.
@MainActor
enum DetailTimings {
    static let argument = "-ate-profile-detail"
    private static var openedAt: [String: ContinuousClock.Instant] = [:]
    private static var previewed: [String: Bool] = [:]

    private static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func opened(_ page: String, hasPreview: Bool) {
        guard isOn else { return }
        openedAt[page] = .now
        previewed[page] = hasPreview
    }

    static func settled(_ page: String) {
        guard isOn, let start = openedAt.removeValue(forKey: page) else { return }
        let elapsed = ContinuousClock.now - start
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let first = previewed[page] == true ? "at_once" : "at_settle"
        append("TIMING \(page) settled_ms=\(ms) first_content=\(first)\n")
    }

    private static func append(_ line: String) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let file = folder.appendingPathComponent("detail-timings.txt")
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
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
