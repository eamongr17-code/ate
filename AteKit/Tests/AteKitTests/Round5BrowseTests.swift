import Foundation
import Testing
@testable import AteKit

@Suite("Round 5 — the score range")
struct ScoreBandTests {
    @Test("the whole track is no filter, and keeps the unscored")
    func wholeTrack() {
        let band = ScoreBand.all
        #expect(band.isAll)
        #expect(band.minScore == nil && band.maxScore == nil)
        #expect(band.title == nil)
        #expect(band.contains(nil))
    }

    @Test("any narrowing leaves the unscored out — even with the bottom end on 0.5")
    func narrowedDropsUnscored() {
        let band = ScoreBand(lower: 0.5, upper: 4)
        #expect(band.minScore == 0.5 && band.maxScore == 4)
        #expect(band.contains(nil) == false)
        #expect(band.contains(3.5))
        #expect(band.contains(4.5) == false)
    }

    @Test("the top end on 5.0 is open: a secret 6 clears it, and no ceiling is sent")
    func openTop() {
        let band = ScoreBand(lower: 4, upper: 5)
        #expect(band.maxScore == nil && band.minScore == 4)
        #expect(band.contains(6))
        #expect(band.title == "4.0+")
        #expect(ScoreBand(lower: 4, upper: 4.5).contains(6) == false)
    }

    @Test("ends snap to half-steps, stay on the track and never cross")
    func snapping() {
        #expect(ScoreBand(lower: 3.3, upper: 4.8) == ScoreBand(lower: 3.5, upper: 5))
        #expect(ScoreBand(lower: -2, upper: 9) == .all)
        let crossed = ScoreBand(lower: 4, upper: 2)
        #expect(crossed.lower == 2 && crossed.upper == 4)
        #expect(ScoreBand(lower: 3, upper: 4).moving(.lower, to: 4.5) == ScoreBand(lower: 4, upper: 4))
        #expect(ScoreBand(lower: 3, upper: 4).moving(.upper, to: 1) == ScoreBand(lower: 3, upper: 3))
    }

    @Test("the track's arithmetic: both ends reachable, the nearer end picks up")
    func track() {
        #expect(ScoreBand.value(atFraction: 0) == 0.5)
        #expect(ScoreBand.value(atFraction: 1) == 5)
        #expect(ScoreBand.fraction(of: 2.75) == ScoreBand.fraction(of: 3))
        let band = ScoreBand(lower: 2, upper: 4)
        #expect(band.nearerEnd(to: 2.5) == .lower)
        #expect(band.nearerEnd(to: 3.5) == .upper)
        let pinched = ScoreBand(lower: 3, upper: 3)
        #expect(pinched.nearerEnd(to: 2) == .lower)
        #expect(pinched.nearerEnd(to: 4) == .upper)
    }

    @Test("the pill: a closed range prints both ends")
    func titles() {
        #expect(ScoreBand(lower: 3, upper: 4.5).title == "3.0–4.5")
        #expect(ScoreBand(lower: 3, upper: 3).title == "3.0")
    }

    @Test("the Journal's query carries the range and the city, and drops them with their pills")
    func journalQuery() {
        var query = JournalQuery(sort: .top, city: "melbourne")
        query.band = ScoreBand(lower: 3, upper: 4)
        #expect(query.pills.map(\.id) == ["sort", "city", "score"])
        #expect(query.filterNames == "min_score,max_score,city")
        let parameters = JournalQueryClient.parameters(for: query, after: nil, pageSize: 20)
        #expect(parameters["p_max_score"] == .double(4))
        #expect(parameters["p_city"] == .string("melbourne"))
        let cleared = query.removing(.band(query.band)).removing(.city("melbourne"))
        #expect(cleared.hasFilters == false)
    }
}

@Suite("Round 5 — the Feed's location")
@MainActor
struct FeedLocationTests {
    private final class Cities: EntryFeedReading, @unchecked Sendable {
        var nearMe: AteCity?
        func feedPage(
            after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
        ) async throws -> Page<EntryCard> {
            Page(items: [], requestedLimit: pageSize)
        }
        func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] { [] }
        func feedCities() async throws -> [AteCity] {
            [
                AteCity(city: "melbourne", name: "Melbourne", entryCount: 30),
                AteCity(city: "sydney", name: "Sydney", entryCount: 3)
            ]
        }
        func resolveCity(latitude: Double?, longitude: Double?) async throws -> AteCity? { nearMe }
    }

    private final class Memory: AteKeyValueStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func value(forKey key: String) -> String? { values[key] }
        func setValue(_ value: String?, forKey key: String) { values[key] = value }
    }

    @Test("near me by default: the feed reads the city the phone is in")
    func nearMeByDefault() async {
        let reader = Cities()
        reader.nearMe = AteCity(city: "melbourne", name: "Melbourne", isNearby: true)
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        #expect(model.location == .nearMe)
        #expect(model.city == nil)
        #expect(await model.resolveNearMe(latitude: -37.8, longitude: 144.9))
        #expect(model.city == "melbourne" && model.isNearMe && model.locationTitle == "Melbourne")
    }

    @Test("no location: the busiest city, and the control does not claim near me")
    func fallback() async {
        let reader = Cities()
        reader.nearMe = AteCity(city: "melbourne", name: "Melbourne", isNearby: false)
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        await model.resolveNearMe(latitude: nil, longitude: nil)
        #expect(model.city == "melbourne" && model.isNearMe == false)
    }

    @Test("no city has food: near me is everywhere")
    func nothingAnywhere() async {
        let model = FeedAreaModel(reader: Cities(), store: Memory(), owner: { nil })
        await model.resolveNearMe(latitude: 1, longitude: 1)
        #expect(model.city == nil && model.locationTitle == "Everywhere")
    }

    @Test("a pick persists per person, and says whether the feed must reload")
    func persistsPerPerson() async {
        let memory = Memory()
        let alice = UUID()
        let model = FeedAreaModel(reader: Cities(), store: memory, owner: { alice })
        #expect(model.choose(location: .city("sydney")))
        #expect(model.choose(location: .city("sydney")) == false)
        #expect(FeedAreaModel(reader: Cities(), store: memory, owner: { alice }).location == .city("sydney"))
        #expect(FeedAreaModel(reader: Cities(), store: memory, owner: { UUID() }).location == .nearMe)
        #expect(FeedLocation(stored: FeedLocation.everywhere.stored) == .everywhere)
    }
}
