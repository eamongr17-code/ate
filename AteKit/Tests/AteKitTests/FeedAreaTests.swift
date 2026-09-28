import Foundation
import Testing
@testable import AteKit

@Suite("Feed area")
struct FeedAreaTests {
    @Test("feed_areas decodes busiest first, ties by name, blanks and repeats dropped")
    func decode() throws {
        let data = Data(#"""
        [{"area":"Carlton","entry_count":3},{"area":"CBD","entry_count":12},
         {"area":"","entry_count":40},{"area":"Brunswick","entry_count":3},{"area":"CBD","entry_count":1},
         {"area":"Fitzroy","count":2}]
        """#.utf8)
        let areas = try FeedArea.decodeList(data)
        #expect(areas.map(\.area) == ["CBD", "Brunswick", "Carlton", "Fitzroy"])
        #expect(areas.map(\.count) == [12, 3, 3, 2])
    }

    @MainActor
    @Test("A choice is remembered per person, and Everywhere is nil")
    func perPerson() {
        let store = InMemoryKeyValueStore()
        let eamon = UUID()
        let jess = UUID()
        let owner = OwnerBox(eamon)
        let model = FeedAreaModel(
            reader: InMemorySocialService(), store: store, owner: { owner.value }
        )
        #expect(model.selected == nil)
        #expect(model.choose("Melbourne"))
        #expect(model.choose("Melbourne") == false)
        #expect(store.value(forKey: FeedAreaModel.key(for: eamon)) == "Melbourne")

        owner.value = jess
        model.reloadSelection()
        #expect(model.selected == nil)

        owner.value = eamon
        let again = FeedAreaModel(reader: InMemorySocialService(), store: store, owner: { owner.value })
        #expect(again.selected == "Melbourne")
        again.choose(nil)
        #expect(store.value(forKey: FeedAreaModel.key(for: eamon)) == nil)
    }

    @MainActor
    @Test("feed_area_changed names the area and its rank; Everywhere has no rank")
    func telemetry() async {
        let events = DeletionEventLog()
        let model = FeedAreaModel(
            reader: InMemorySocialService(), store: InMemoryKeyValueStore(), owner: { nil },
            analytics: events.record
        )
        await model.loadAreas()
        // The seed: most visits in the CBD, one in North Melbourne.
        #expect(model.areas.map(\.area) == ["CBD", "North Melbourne"])
        #expect(model.hasReachedEnd)
        model.choose("North Melbourne")
        model.choose(nil)
        #expect(events.events == [
            AnalyticsEvent(name: "feed_area_changed", parameters: ["area": "North Melbourne", "rank": "1"]),
            AnalyticsEvent(name: "feed_area_changed", parameters: ["area": "everywhere"])
        ])
    }

    @Test("The keyset: busier first, then by name — and a cursor pages strictly after itself")
    func keyset() {
        let cbd = FeedArea(area: "CBD", count: 5)
        #expect(FeedArea.isAfter(FeedArea(area: "Carlton", count: 3), cursor: cbd))
        #expect(FeedArea.isAfter(FeedArea(area: "Collingwood", count: 5), cursor: cbd))
        #expect(FeedArea.isAfter(FeedArea(area: "Abbotsford", count: 5), cursor: cbd) == false)
        #expect(FeedArea.isAfter(cbd, cursor: cbd) == false)
        #expect(FeedArea.clampedLimit(500) == 100)
        #expect(FeedArea.clampedLimit(0) == 1)
    }

    @MainActor
    @Test("The sheet pages feed_areas as it scrolls, deduped, until a short page")
    func paging() async {
        let areas = (1...5).map { FeedArea(area: "Area \($0)", count: 10 - $0) }
        let reader = PagedAreas(areas)
        let model = FeedAreaModel(
            reader: reader, store: InMemoryKeyValueStore(), owner: { nil }, pageSize: 2
        )
        await model.loadAreas()
        #expect(model.areas.map(\.area) == ["Area 1", "Area 2"])
        #expect(model.hasReachedEnd == false)
        await model.loadMoreAreasIfNeeded(after: model.areas[1])
        await model.loadMoreAreas()
        #expect(model.areas.map(\.area) == ["Area 1", "Area 2", "Area 3", "Area 4", "Area 5"])
        #expect(model.hasReachedEnd)
        #expect(reader.cursors == [nil, "Area 2", "Area 4"])
        // Reopening starts again from the top: counts move.
        await model.loadAreas()
        #expect(model.areas.count == 2)
    }

    @MainActor
    @Test("Changing area starts the list again from nothing, and reads the new area")
    func reloadForArea() async {
        let areas = AreaBox()
        let store = EntryListStore(fallbackMessage: "x") { _, size in
            let area = await areas.value
            return Page(
                items: area == nil ? [BrowseFixtures.card(1), BrowseFixtures.card(2)] : [BrowseFixtures.card(3)],
                requestedLimit: size
            )
        }
        await store.loadIfNeeded()
        #expect(store.entries.count == 2)
        await areas.set("Carlton")
        await store.reload()
        #expect(store.entries.count == 1)
        #expect(store.phase == .ready)
        #expect(store.pagesLoaded == 1)
    }

    @Test("The in-memory feed filters by area, and everywhere is everything")
    func filter() async throws {
        let social = InMemorySocialService(entries: [
            BrowseFixtures.card(1, city: "Melbourne"), BrowseFixtures.card(2, city: "Sydney")
        ])
        let everywhere = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: nil)
        let sydney = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: "Sydney")
        #expect(everywhere.items.count == 2)
        #expect(sydney.items.count == 1)
    }
}

@MainActor
@Suite("Feed area — read ahead")
struct FeedAreaReadAheadTests {
    @Test func theFeedsAreasAreReadAheadOnce() async {
        let reader = CountingAreas()
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        #expect(model.hasLoadedAreas == false)
        await model.loadAreasIfNeeded()
        await model.loadAreasIfNeeded()
        #expect(model.hasLoadedAreas)
        #expect(model.areas.map(\.area) == ["CBD", "Fitzroy"])
        #expect(await reader.calls == 1)
    }

    @Test func aFailedReadStillAnswersTheSheetAndIsAskedAgain() async {
        let reader = CountingAreas(failing: true)
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        await model.loadAreasIfNeeded()
        #expect(model.hasAnsweredAreas, "no still rows left standing in an open sheet")
        #expect(model.hasLoadedAreas == false)
        await model.loadAreasIfNeeded()
        #expect(await reader.calls == 2, "the next open asks again")
    }

    @Test func aSheetWaitingOnAReadAheadWaitsForItToLand() async {
        let reader = SlowAreas()
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        let ahead = Task { await model.loadAreasIfNeeded() }
        await Task.yield()
        await model.loadAreasIfNeeded() // the sheet's prepare, while the read-ahead is in flight
        #expect(model.hasLoadedAreas, "joined the read, did not skip past it")
        await ahead.value
        #expect(await reader.calls == 1)
    }
}

/// `feed_areas`, paged the way the server pages it — and remembering the cursors it was handed.
private final class PagedAreas: EntryFeedReading, TestFake, @unchecked Sendable {
    private let all: [FeedArea]
    private let lock = NSLock()
    private var asked: [String?] = []

    init(_ all: [FeedArea]) { self.all = all }

    var cursors: [String?] { lock.withLock { asked } }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        lock.withLock {
            asked.append(cursor?.area)
            let rest = cursor.map { cursor in all.filter { FeedArea.isAfter($0, cursor: cursor) } } ?? all
            return Array(rest.prefix(limit))
        }
    }
}

@MainActor
private final class AreaBox {
    var value: String?
    func set(_ area: String?) { value = area }
}

private final class OwnerBox: @unchecked Sendable {
    var value: UUID?
    init(_ value: UUID?) { self.value = value }
}

/// One area, slowly.
private actor SlowAreas: EntryFeedReading, TestFake {
    var calls = 0

    func feedPage(
        after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
    ) async throws -> Page<EntryCard> {
        Page(items: [], nextCursor: nil)
    }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        calls += 1
        try? await Task.sleep(for: .milliseconds(80))
        return [FeedArea(area: "CBD", count: 9)]
    }
}

/// Two areas, and how many times they were asked for.
private actor CountingAreas: EntryFeedReading, TestFake {
    var calls = 0
    let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    func feedPage(
        after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
    ) async throws -> Page<EntryCard> {
        Page(items: [], nextCursor: nil)
    }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        calls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return [FeedArea(area: "CBD", count: 9), FeedArea(area: "Fitzroy", count: 4)]
    }
}
