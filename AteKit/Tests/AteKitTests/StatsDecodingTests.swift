import Foundation
import Testing

@testable import AteKit

/// **What the stats RPCs actually send**, decoded against the payloads written down in
/// `docs/backend/integration-design.md` and observed on staging — including the nulls the happy
/// path never shows you.
@Suite("Stats decoding")
struct StatsDecodingTests {

    // MARK: - score_histogram

    @Test("Ten half-step buckets decode with their two different counts")
    func histogramDecodes() throws {
        let json = Data("""
        [{"score":0.5,"dish_count":1,"review_count":1},
         {"score":1.0,"dish_count":0,"review_count":0},
         {"score":1.5,"dish_count":1,"review_count":1},
         {"score":2.0,"dish_count":0,"review_count":0},
         {"score":2.5,"dish_count":1,"review_count":1},
         {"score":3.0,"dish_count":3,"review_count":3},
         {"score":3.5,"dish_count":10,"review_count":10},
         {"score":4.0,"dish_count":15,"review_count":16},
         {"score":4.5,"dish_count":19,"review_count":22},
         {"score":5.0,"dish_count":6,"review_count":6}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([ScoreBucket].self, from: json)
        let histogram = ScoreHistogram(rows)

        #expect(histogram.buckets.count == 10)
        #expect(histogram.buckets.map(\.score) == ScoreHistogram.scores)
        #expect(histogram.dishCount(at: 4.5) == 19)
        // The two counts are different questions: two sittings of one dish is 1 dish, 2 reviews.
        #expect(histogram.bucket(at: 4.5).reviewCount == 22)
        #expect(histogram.peak == 19)
        #expect(histogram.total == 56)
        #expect(histogram.isEmpty == false)
    }

    /// The RPC promises all ten. A client that trusts a promise and gets nine draws a chart with a
    /// hole in it, so the gap is filled at zero rather than dropped.
    @Test("A short answer is still ten bars, and the missing ones are empty")
    func histogramFillsGaps() {
        let histogram = ScoreHistogram([
            ScoreBucket(score: 4.0, dishCount: 3, reviewCount: 3),
            ScoreBucket(score: 5.0, dishCount: 1, reviewCount: 1)
        ])
        #expect(histogram.buckets.count == 10)
        #expect(histogram.dishCount(at: 0.5) == 0)
        #expect(histogram.dishCount(at: 4) == 3)
    }

    @Test("Anything off the half-step grid is not a bar")
    func histogramIgnoresJunk() {
        let histogram = ScoreHistogram([
            ScoreBucket(score: 0, dishCount: 9, reviewCount: 9),
            ScoreBucket(score: 5.5, dishCount: 9, reviewCount: 9),
            ScoreBucket(score: 3.5, dishCount: 2, reviewCount: 2)
        ])
        #expect(histogram.total == 2)
        #expect(histogram.peak == 2)
    }

    /// Design rule 7: a score is never inferred. An empty bucket draws nothing, because a stub bar
    /// reads as "you gave one of those".
    @Test("An empty bucket has no height, and a tiny one still has some")
    func histogramFractions() {
        let histogram = ScoreHistogram([
            ScoreBucket(score: 1.0, dishCount: 0, reviewCount: 0),
            ScoreBucket(score: 2.0, dishCount: 1, reviewCount: 1),
            ScoreBucket(score: 4.0, dishCount: 50, reviewCount: 50)
        ])
        #expect(histogram.fraction(at: 1) == 0)
        #expect(histogram.fraction(at: 2) == 0.02)
        #expect(histogram.fraction(at: 4) == 1)
        #expect(ScoreHistogram.empty.fraction(at: 4) == 0)
    }

    @Test("The chart opens on the fullest bar, and the higher score breaks a tie")
    func histogramBusiest() {
        #expect(ScoreHistogram.empty.busiestScore == nil)
        let clear = ScoreHistogram([
            ScoreBucket(score: 3.5, dishCount: 4, reviewCount: 4),
            ScoreBucket(score: 4.0, dishCount: 9, reviewCount: 9)
        ])
        #expect(clear.busiestScore == 4.0)
        let tied = ScoreHistogram([
            ScoreBucket(score: 2.0, dishCount: 7, reviewCount: 7),
            ScoreBucket(score: 4.5, dishCount: 7, reviewCount: 7)
        ])
        #expect(tied.busiestScore == 4.5)
    }

    /// The wire value is a decimal string parsed into a binary double; bar identity must survive it.
    @Test("A score snaps to a half-step and stays inside the scale")
    func snapping() {
        #expect(ScoreHistogram.snapped(4.4999999) == 4.5)
        #expect(ScoreHistogram.snapped(4.3) == 4.5)
        #expect(ScoreHistogram.snapped(0) == 0.5)
        #expect(ScoreHistogram.snapped(9) == 5)
        #expect(ScoreHistogram.halfSteps(4.5) == 9)
    }

    // MARK: - dishes_by_score

    /// `entry_id` really is null on staging rows — a review can outlive the entry it was written in.
    @Test("A scored dish decodes, including the null entry it came from")
    func scoredDishDecodes() throws {
        let json = Data("""
        [{"review_id":"2c632a86-8a47-4bcb-8d93-0c2c9a626061","entry_id":null,
          "dish_id":"416e9483-96b5-49d3-83e4-cee1d4e2c33b","dish_name":"Margarita Fishbowl",
          "restaurant_id":"fd685707-24c9-44ee-94b5-37a03e235610",
          "restaurant_name":"PJ’s Mexican cantina","score":5.0,"note":"Deliciousiation",
          "created_at":"2026-09-05T11:31:36.372994+00:00",
          "cover_url":"https://example.test/margarita.jpg"}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([ScoredDish].self, from: json)
        let dish = try #require(rows.first)
        #expect(dish.entryID == nil)
        #expect(dish.dishName == "Margarita Fishbowl")
        #expect(dish.restaurantName == "PJ’s Mexican cantina")
        #expect(dish.score == 5)
        #expect(dish.note == "Deliciousiation")
        // Microseconds, not milliseconds — the reason ``PostgRESTDate`` exists.
        #expect(abs(dish.createdAt.timeIntervalSince1970 - 1_788_607_896.372994) < 0.0005)
        #expect(dish.coverURL == "https://example.test/margarita.jpg")
        // The row is a review, so the same dish twice in one list is two rows — and the keyset
        // cursor is the review's, not the dish's.
        #expect(dish.id == dish.reviewID)
        #expect(dish.pageCursor.id == dish.reviewID)
        #expect(dish.pageCursor.createdAt == dish.createdAt)
    }

    // MARK: - statement_months

    /// A dish nobody has photographed. The tile is the field colour, never a broken-image mark.
    @Test("A row with no photo and no entry behind it still decodes")
    func scoredDishWithoutExtras() throws {
        let json = Data(#"""
        [{"review_id":"2c632a86-8a47-4bcb-8d93-0c2c9a626061","entry_id":null,
          "dish_id":"416e9483-96b5-49d3-83e4-cee1d4e2c33b","dish_name":"Toast",
          "restaurant_id":null,"restaurant_name":null,"score":3.0,"note":null,
          "created_at":"2026-09-05T11:31:36+00:00","cover_url":null}]
        """#.utf8)
        let dish = try #require(try PostgRESTDate.decoder.decode([ScoredDish].self, from: json).first)
        #expect(dish.coverURL == nil)
        #expect(dish.restaurantName == nil)
        #expect(dish.entryID == nil)
    }

    @Test("A month is a year and a month, never an instant")
    func monthsDecode() throws {
        let json = Data("""
        [{"month":"2026-09-01","orders":10},{"month":"2026-08-01","orders":7}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([StatementMonthSummary].self, from: json)
        #expect(rows.map(\.month) == [
            StatementMonth(year: 2026, month: 9), StatementMonth(year: 2026, month: 8)
        ])
        #expect(rows.first?.orders == 10)
        #expect(rows.first?.month.parameter == "2026-09-01")
        #expect(rows.first?.month.key == "2026-09")
    }

    /// The whole reason this is not a `Date`: UTC midnight on the first of September is the 31st of
    /// August in Los Angeles, and a statement that renames itself west of Greenwich is a bug.
    @Test("September is September wherever the reader is standing")
    func monthsAreNotInstants() throws {
        let month = try #require(StatementMonth(iso: "2026-09-01"))
        #expect(month.year == 2026)
        #expect(month.month == 9)
        #expect(StatementMonth(iso: "2026-09") == month)
        #expect(StatementMonth(iso: "not-a-month") == nil)
        #expect(StatementMonth(iso: "2026-13-01") == nil)
    }

    @Test("A month knows which side of another it is on")
    func monthsCompare() {
        #expect(StatementMonth(year: 2026, month: 1) > StatementMonth(year: 2025, month: 12))
        #expect(StatementMonth(year: 2026, month: 8) < StatementMonth(year: 2026, month: 9))
    }

    // MARK: - monthly_statement

    @Test("The statement's nine figures and three lists decode")
    func statementDecodes() throws {
        let json = Data("""
        {"month":"2026-09-01","username":"eamon","stars":86.0,"dishes":23,"orders":10,
         "places":7,"average":4.1,"new_places":2,
         "top_dishes":[{"score":4.5,"dish_id":"601d455e-9b61-47b7-98e0-8dfdd5735d17",
                        "dish_name":"Salmon roll","restaurant_name":"Tipo 00"}],
         "most_ordered":{"count":1,"dish_name":"Beef tartare"},
         "most_visited":{"count":2,"restaurant_id":"a0000000-0000-4000-8000-000000000007",
                         "restaurant_name":"Baby Pizza"}}
        """.utf8)
        let statement = try PostgRESTDate.decoder.decode(MonthlyStatement.self, from: json)

        #expect(statement.month == StatementMonth(year: 2026, month: 9))
        // The signature travels with the figures — a receipt is never signed from a second call.
        #expect(statement.username == "eamon")
        #expect(statement.orders == 10)
        #expect(statement.places == 7)
        #expect(statement.newPlaces == 2)
        #expect(statement.dishes == 23)
        #expect(statement.stars == 86)
        #expect(statement.average == 4.1)
        #expect(statement.topDishes.count == 1)
        #expect(statement.topDishes.first?.restaurantName == "Tipo 00")
        #expect(statement.mostOrdered?.dishName == "Beef tartare")
        #expect(statement.mostVisited?.restaurantName == "Baby Pizza")
        #expect(statement.mostVisited?.count == 2)
    }

    /// A month where nothing was scored: `average` is null and the lists are empty. It must decode
    /// — the bands that have nothing behind them are simply not printed (design rule 4) — and the
    /// average must stay `nil`, never `0.0` (data-model §1.3).
    @Test("An unscored month decodes with a null average and no top dishes")
    func statementWithNothingScored() throws {
        let json = Data("""
        {"month":"2026-02-01","username":"eamon","orders":1,"places":0,"new_places":0,
         "dishes":2,"stars":0,"average":null,"top_dishes":[],
         "most_ordered":{"count":2,"dish_name":"Toast"},"most_visited":null}
        """.utf8)
        let statement = try PostgRESTDate.decoder.decode(MonthlyStatement.self, from: json)
        #expect(statement.average == nil)
        #expect(statement.topDishes.isEmpty)
        #expect(statement.mostVisited == nil)
        #expect(statement.mostOrdered?.count == 2)
        #expect(ScoreFormat.average(statement.average) == ScoreFormat.unratedPlaceholder)
    }

    /// The jsonb can gain a key additively; a statement we would rather draw short than not at all.
    @Test("A statement missing a count still draws, at zero")
    func statementTolerates() throws {
        let json = Data(#"{"month":"2026-03-01","orders":4}"#.utf8)
        let statement = try PostgRESTDate.decoder.decode(MonthlyStatement.self, from: json)
        #expect(statement.orders == 4)
        #expect(statement.username == nil)
        #expect(statement.dishes == 0)
        #expect(statement.stars == 0)
        #expect(statement.average == nil)
    }

    /// Scores print like prices — one decimal for a rating, a dropped `.0` for a total.
    @Test("Stars and averages print the way a receipt prints them")
    func statementFormatting() {
        #expect(ScoreFormat.starsTotal(57.5) == "57.5")
        #expect(ScoreFormat.starsTotal(86) == "86")
        #expect(ScoreFormat.average(4.1) == "4.1")
        #expect(ScoreFormat.average(4.0) == "4.0")
        #expect(ScoreFormat.halfStep(4.5) == "4.5")
        #expect(ScoreFormat.dishCount(36) == "36 dishes")
        #expect(ScoreFormat.dishCount(1) == "1 dish")
        #expect(ScoreFormat.dishCount(0) == "0 dishes")
    }
}
