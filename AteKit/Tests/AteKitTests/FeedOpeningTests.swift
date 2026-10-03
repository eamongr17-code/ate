import Foundation
import Testing
@testable import AteKit

/// The rebuilt Feed opens on your Journal's city, and asks for no location until Near me is tapped
/// (pattern contract §6, Eamon 3 Oct).
@Suite("Where the Feed opens")
@MainActor
struct FeedOpeningTests {
    private final class Cities: EntryFeedReading, TestFake, @unchecked Sendable {
        var resolveCalls = 0
        func feedPage(
            after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
        ) async throws -> Page<EntryCard> {
            Page(items: [], requestedLimit: pageSize)
        }
        func feedCities() async throws -> [AteCity] { [] }
        func resolveCity(latitude: Double?, longitude: Double?) async throws -> AteCity? {
            resolveCalls += 1
            return AteCity(city: "melbourne", name: "Melbourne", isNearby: true)
        }
    }

    private final class Memory: AteKeyValueStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func value(forKey key: String) -> String? { values[key] }
        func setValue(_ value: String?, forKey key: String) { values[key] = value }
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    private let melbourne = AteCity(city: "melbourne", name: "Melbourne", entryCount: 3)
    private let sydney = AteCity(city: "sydney", name: "Sydney", entryCount: 12)

    @Test("the Journal's busiest city, then the busiest city with food, then everywhere")
    func rule() {
        #expect(FeedAreaModel.openingLocation(journalCities: [melbourne, sydney], feedCities: []) == .city("sydney"))
        #expect(FeedAreaModel.openingLocation(journalCities: [], feedCities: [melbourne]) == .city("melbourne"))
        #expect(FeedAreaModel.openingLocation(journalCities: [], feedCities: []) == .everywhere)
    }

    @Test("never picked: the first read is the opening city, no location is asked, nothing is stored")
    func opensOnTheJournalCity() async {
        let reader = Cities()
        let memory = Memory()
        let model = FeedAreaModel(reader: reader, store: memory, owner: { nil })
        let asked = Counter()
        model.locate = {
            asked.value += 1
            return (latitude: 1, longitude: 1)
        }
        model.opening = { .city("sydney") }
        #expect(model.hasOpened == false)
        #expect(await model.cityForFirstPage() == "sydney")
        #expect(model.hasOpened && model.location == .city("sydney"))
        #expect(asked.value == 0 && reader.resolveCalls == 0)
        #expect(model.hasChosenLocation == false && memory.values.isEmpty)
    }

    @Test("a stored pick wins over the opening")
    func pickWins() async {
        let memory = Memory()
        memory.values[FeedAreaModel.locationKey(for: nil)] = FeedLocation.everywhere.stored
        let model = FeedAreaModel(reader: Cities(), store: memory, owner: { nil })
        let opened = Counter()
        model.opening = {
            opened.value += 1
            return .city("sydney")
        }
        #expect(await model.cityForFirstPage() == nil)
        #expect(opened.value == 0 && model.location == .everywhere && model.hasOpened)
    }

    @Test("two first reads at once work the opening out once")
    func once() async {
        let model = FeedAreaModel(reader: Cities(), store: Memory(), owner: { nil })
        let opened = Counter()
        model.opening = {
            opened.value += 1
            try? await Task.sleep(for: .milliseconds(20))
            return .city("sydney")
        }
        async let first = model.cityForFirstPage()
        async let second = model.cityForFirstPage()
        let cities = await [first, second]
        #expect(cities == ["sydney", "sydney"])
        #expect(opened.value == 1)
    }

    @Test("Near me, once picked, is remembered and read from the phone")
    func nearMeAfterPick() async {
        let reader = Cities()
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        model.opening = { .city("sydney") }
        _ = await model.cityForFirstPage()
        model.locate = { (latitude: 1, longitude: 1) }
        #expect(model.choose(location: .nearMe))
        #expect(model.hasChosenLocation)
        #expect(await model.cityForFirstPage() == "melbourne")
        #expect(model.isNearMe)
    }
}
