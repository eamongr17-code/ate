import Foundation
import Testing
@testable import AteKit

/// The journal's days and counts on the wire: `journal_days` and `my_entries_count` as data, and the
/// grouping a reader without `journal_days` falls back to.
@MainActor
@Suite("Journal days")
struct JournalDaysTests {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }

    private static func card(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
        scores: [Double?] = [4], photo: String? = nil
    ) -> EntryCard {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return EntryCard(
            id: UUID(),
            authorID: ViewerProfile.preview.id,
            body: "Words",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: date,
            photos: photo.map { [EntryCard.Photo(url: $0, position: 0)] } ?? [],
            items: scores.enumerated().map { index, score in
                EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Dish \(index)",
                               score: score.flatMap { Rating(exactly: $0) }, position: index + 1)
            }
        )
    }

    // MARK: - The wire

    @Test("a journal_days row decodes: the day as a date, a null best score, a 6")
    func decoding() throws {
        let json = Data("""
        [{"day":"2026-09-16","entries":2,"best_score":6,"cover_url":"https://x/y.jpg"},
         {"day":"2026-09-17","entries":1,"best_score":null,"cover_url":null}]
        """.utf8)
        let rows = try JSONDecoder().decode([JournalDayCount].self, from: json)
        #expect(rows[0].day == AteDay(year: 2026, month: 9, day: 16))
        #expect(rows[0].mark == .six && rows[0].coverURL == "https://x/y.jpg")
        #expect(rows[1].bestScore == nil && rows[1].mark == .visit)
        #expect(AteDay("2026-02-30x") != nil && AteDay("nope") == nil)
    }

    @Test("my_entries_count takes my_entries' filters and nothing else")
    func countParameters() throws {
        var query = JournalQuery(sort: .top, city: "melbourne", window: AteMonth(year: 2026, month: 9).window)
        query.band = ScoreBand.Preset.fourPlus.band
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        let parameters = JournalQueryClient.countParameters(for: query, timeZone: melbourne)
        #expect(Set(parameters.keys) == ["p_min_score", "p_max_score", "p_city", "p_from", "p_to", "p_tz",
                                          "p_restaurant_id", "p_tag"])
        #expect(parameters["p_min_score"] == .double(4) && parameters["p_max_score"] == .null)
        #expect(parameters["p_from"] == .string("2026-09-01") && parameters["p_to"] == .string("2026-09-30"))
        #expect(try JournalQueryClient.decodeCount(Data("14".utf8)) == 14)
        #expect(try JournalQueryClient.decodeCount(Data(#"[{"count":3}]"#.utf8)) == 3)
    }

    @Test("journal_days takes the range, the zone and the list's filters, never its months")
    func daysParameters() {
        var query = JournalQuery(sort: .top, city: "melbourne", window: AteMonth(year: 2026, month: 3).window)
        query.band = ScoreBand.Preset.fives.band
        let tz = TimeZone(identifier: "Australia/Melbourne")!
        let from = AteDay(year: 2026, month: 9, day: 1)
        let to = AteDay(year: 2026, month: 9, day: 30)
        let filtered = JournalQueryClient.daysParameters(from: from, to: to, matching: query, timeZone: tz)
        #expect(filtered["p_from"] == .string("2026-09-01") && filtered["p_to"] == .string("2026-09-30"))
        #expect(filtered["p_min_score"] == .double(5) && filtered["p_max_score"] == .double(5))
        #expect(filtered["p_city"] == .string("melbourne") && filtered["p_tz"] == .string("Australia/Melbourne"))
        #expect(filtered["p_sort"] == nil && filtered["p_limit"] == nil)
        let plain = JournalQueryClient.daysParameters(from: from, to: to, matching: nil, timeZone: tz)
        #expect(Set(plain.keys) == ["p_from", "p_to", "p_tz"])
    }

    @Test("a day is marked by its best score: 6 brick, 5.0 butter, anything else a visit")
    func marks() {
        #expect(JournalDayMark(bestScore: 6) == .six)
        #expect(JournalDayMark(bestScore: 5) == .five)
        #expect(JournalDayMark(bestScore: 4.5) == .visit)
        #expect(JournalDayMark(bestScore: nil) == .visit, "unscored is a visit, never a guess")
    }

    // MARK: - Deriving the days

    @Test("a reader without journal_days groups the entries by day: count, best, newest cover")
    func grouping() async throws {
        let cards = [
            Self.card(2026, 9, 16, hour: 9, scores: [4], photo: "morning"),
            Self.card(2026, 9, 16, hour: 20, scores: [6, 3], photo: "evening"),
            Self.card(2026, 9, 17, scores: [nil]),
            Self.card(2026, 8, 31, scores: [5])
        ]
        let rows = JournalDayCount.grouping(
            cards, from: AteDay(year: 2026, month: 9, day: 1), to: AteDay(year: 2026, month: 9, day: 30),
            calendar: Self.utc
        )
        #expect(rows.map(\.day.day) == [16, 17])
        #expect(rows[0].entries == 2 && rows[0].bestScore == 6 && rows[0].coverURL == "evening")
        #expect(rows[1].bestScore == nil && rows[1].coverURL == nil)
    }
}
