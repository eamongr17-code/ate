import Foundation
import Testing
@testable import AteKit

@Suite("The score range")
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

    @Test("the top end on 6 is open and sends no ceiling; on 5.0 it is a ceiling a 6 is above")
    func openTop() {
        let band = ScoreBand(lower: 4, upper: 6)
        #expect(band.maxScore == nil && band.minScore == 4)
        #expect(band.contains(6))
        #expect(band.title == "4.0+")
        #expect(band.summary == "4.0 and up")
        let closed = ScoreBand(lower: 4, upper: 5)
        #expect(closed.maxScore == 5 && closed.contains(6) == false && closed.contains(5))
        #expect(ScoreBand(lower: 4, upper: 4.5).contains(6) == false)
    }

    @Test("the presets: 5.0s is exactly 5.0, 6s only is the secret 6, each printed by name")
    func presets() {
        #expect(ScoreBand.Preset.fives.band.contains(5) && ScoreBand.Preset.fives.band.contains(6) == false)
        #expect(ScoreBand.Preset.fives.band.title == "5.0s")
        let sixes = ScoreBand.Preset.sixes.band
        #expect(sixes.minScore == 6 && sixes.maxScore == nil)
        #expect(sixes.contains(6) && sixes.contains(5) == false && sixes.contains(nil) == false)
        #expect(sixes.title == "6s only" && sixes.summary == "6s only")
        #expect(ScoreBand.Preset.fourPlus.band == ScoreBand(lower: 4, upper: 6))
        #expect(ScoreBand(lower: 3, upper: 6).preset == .threePlus)
        #expect(ScoreBand.all.preset == .any && ScoreBand.all.summary == "Any")
        #expect(ScoreBand(lower: 3, upper: 4).preset == nil)
    }

    @Test("ends snap to half-steps, stay on the track and never cross")
    func snapping() {
        #expect(ScoreBand(lower: 3.3, upper: 4.8) == ScoreBand(lower: 3.5, upper: 5))
        #expect(ScoreBand(lower: 5.6, upper: 5.6) == ScoreBand.Preset.sixes.band, "past 5.0 the next stop is 6")
        #expect(ScoreBand(lower: -2, upper: 9) == .all)
        let crossed = ScoreBand(lower: 4, upper: 2)
        #expect(crossed.lower == 2 && crossed.upper == 4)
        #expect(ScoreBand(lower: 3, upper: 4).moving(.lower, to: 4.5) == ScoreBand(lower: 4, upper: 4))
        #expect(ScoreBand(lower: 3, upper: 4).moving(.upper, to: 1) == ScoreBand(lower: 3, upper: 3))
    }

    @Test("the track's arithmetic: both ends reachable, the nearer end picks up")
    func track() {
        #expect(ScoreBand.value(atFraction: 0) == 0.5)
        #expect(ScoreBand.value(atFraction: 1) == 6)
        #expect(ScoreBand.stops == 11)
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
