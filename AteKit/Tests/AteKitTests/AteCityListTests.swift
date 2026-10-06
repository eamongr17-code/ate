import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("A filter's cities, read ahead")
struct AteCityListTests {
    private final class Counter: @unchecked Sendable {
        var reads = 0
        var failing = false
    }

    @Test("a read in the air is joined, and an answered list is not read again")
    func joinsAndRemembers() async {
        let counter = Counter()
        let list = AteCityList {
            counter.reads += 1
            try? await Task.sleep(for: .milliseconds(50))
            return [AteCity(city: "melbourne", name: "Melbourne")]
        }
        async let first: Void = list.loadIfNeeded()
        async let second: Void = list.loadIfNeeded()
        _ = await (first, second)
        #expect(counter.reads == 1 && list.hasLoaded && list.cities.count == 1)
        await list.loadIfNeeded()
        #expect(counter.reads == 1)
        await list.load()
        #expect(counter.reads == 2, "a pull to refresh reads it afresh")
    }

    @Test("a failure answers the sheet, keeps the list, and is asked again next time")
    func failureRetries() async {
        let counter = Counter()
        counter.failing = true
        let list = AteCityList {
            counter.reads += 1
            if counter.failing { throw URLError(.notConnectedToInternet) }
            return [AteCity(city: "sydney", name: "Sydney")]
        }
        await list.loadIfNeeded()
        #expect(list.hasLoaded && list.cities.isEmpty)
        counter.failing = false
        await list.loadIfNeeded()
        #expect(counter.reads == 2 && list.cities.map(\.city) == ["sydney"])
    }
}

@MainActor
@Suite("Cities — slugs, and the Journal's reader")
struct AteCitySlugTests {
    @Test("the Journal's cities come from its reader")
    func journalCities() async {
        let entries = InMemoryEntryService()
        let store = JournalStore(entries: entries, querying: InMemoryJournalQuery(entries: entries))
        await store.loadCities()
        #expect(store.cities.allSatisfy { $0.city == AteCity.slug(for: $0.name) })
    }

    @Test("slugs and names go both ways")
    func slugs() {
        #expect(AteCity.slug(for: "Gold Coast") == "gold-coast")
        #expect(AteCity.slug(for: "  ") == nil)
        #expect(AteCity.displayName(for: "gold-coast") == "Gold Coast")
        #expect(AteCity.displayName(for: "melbourne", in: [AteCity(city: "melbourne", name: "Melb")]) == "Melb")
    }
}

@Suite("The Feed's location search")
struct AteCitySearchTests {
    static let cities = [
        AteCity(city: "melbourne", name: "Melbourne", region: "Victoria"),
        AteCity(city: "adelaide", name: "Adelaide", region: "South Australia"),
        AteCity(city: "geelong", name: "Geelong", region: "Victoria"),
        AteCity(city: "sao-paulo", name: "São Paulo")
    ]

    @Test("a typed search keeps cities by name or region, ignoring case and accents, in order")
    func matches() {
        #expect(AteCity.matching(Self.cities, query: "ADE").map(\.city) == ["adelaide"])
        #expect(AteCity.matching(Self.cities, query: "vic").map(\.city) == ["melbourne", "geelong"])
        #expect(AteCity.matching(Self.cities, query: "sao").map(\.city) == ["sao-paulo"])
        #expect(AteCity.matching(Self.cities, query: "zzz").isEmpty)
    }

    @Test("an empty or blank search keeps everything, and the fixed answers only when they match")
    func blankAndFixed() {
        #expect(AteCity.matching(Self.cities, query: "  ").count == Self.cities.count)
        #expect(AteCity.title("Near me", matches: ""))
        #expect(AteCity.title("Near me", matches: "near"))
        #expect(AteCity.title("Everywhere", matches: "mel") == false)
    }
}
