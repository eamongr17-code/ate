import Foundation
import Testing

@testable import AteKit

/// **Plate awards** (0098): the catalogue, the wire rows, the Awards page's one grid, the takeover's
/// queue and the dishes behind an opened award.
@Suite("Plate awards")
@MainActor
struct PlateAwardsTests {

    private static let day: TimeInterval = 86_400
    private static let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    private static func held(_ award: PlateAward, days: Double, seen: Bool = true) -> EarnedAward {
        EarnedAward(award: award, earnedAt: t0.addingTimeInterval(days * day), seen: seen)
    }

    // MARK: - The catalogue

    @Test("Nineteen awards, the server's ids, the approved names; the first drink is retired")
    func catalogue() {
        #expect(PlateAward.allCases.count == 19)
        #expect(PlateAward(rawValue: "first_drink") == nil)
        #expect(PlateAward.dishes25.rawValue == "dishes_25")
        #expect(PlateAward.firstHalf.rawValue == "first_half")
        #expect(PlateAward.savedBySomeone.name == "Dish saved by someone")
        #expect(PlateAward.allCases.filter(\.isSecret) == [.first6])
        #expect(Set(PlateAward.allCases.map(\.stillName)).count == 19)
    }

    @Test("What an opened award shows, by type")
    func openings() {
        #expect(PlateAward.dishes25.opening == .mosaic(25))
        #expect(PlateAward.dishes1.opening == .entries, "one dish is that dish's entry")
        #expect(PlateAward.first5.opening == .entries)
        #expect(PlateAward.threeInDay.opening == .entries)
        #expect(PlateAward.fiveAtPlace.opening == .dishes)
        #expect(PlateAward.saves10.opening == .dishes)
        #expect(PlateAward.dishesToNext(after: 29) == 21)
        #expect(PlateAward.dishesToNext(after: 0) == 1)
        #expect(PlateAward.dishesToNext(after: 500) == nil)
    }

    // MARK: - The wire

    @Test("awards_of rows decode; an award this build does not know is skipped, not fatal")
    func decoding() throws {
        let json = """
        [{"award":"dishes_25","earned_at":"2026-10-18T09:00:00.123456+00:00",
          "entry_id":"00000000-0000-4000-8000-000000000001",
          "dish_id":null,"entry_ids":[],"dish_ids":[],"other_user_id":null,"other_handle":null,"seen":false,
          "dish_name":"Cacio e Pepe","restaurant_name":"Tipo 00","score":4.5},
         {"award":"first_bonsai","earned_at":"2026-10-18T09:00:00+00:00","seen":true},
         {"award":"saved_by_someone","earned_at":"2026-10-24T09:00:00+00:00","entry_ids":[],
          "dish_ids":["00000000-0000-4000-8000-000000000002"],
          "other_user_id":"00000000-0000-4000-8000-00000000000b","other_handle":"paris","seen":true,
          "dish_name":"Kingfish Crudo","restaurant_name":"Saint Peter","score":null}]
        """
        let rows = try PostgRESTDate.decoder.decode(AwardRows.self, from: Data(json.utf8)).awards
        #expect(rows.map(\.award) == [.dishes25, .savedBySomeone])
        #expect(rows[0].seen == false)
        #expect(rows[0].score == 4.5)
        #expect(rows[0].entries.count == 1)
        #expect(rows[0].dishLine == "Cacio e Pepe at Tipo 00")
        #expect(rows[1].dishLine == "Kingfish Crudo at Saint Peter, saved by @paris")
    }

    @Test("award_lines rows decode, and page on (created_at, review_id)")
    func lines() throws {
        let json = """
        [{"review_id":"00000000-0000-4000-8000-000000000003","entry_id":null,
          "dish_id":"00000000-0000-4000-8000-000000000004",
          "dish_name":"Gnocchi","restaurant_id":null,"restaurant_name":null,"score":null,
          "created_at":"2026-09-01T09:00:00+00:00","photo_url":null}]
        """
        let rows = try PostgRESTDate.decoder.decode([AwardLine].self, from: Data(json.utf8))
        #expect(rows.first?.dishName == "Gnocchi")
        #expect(rows.first?.cursor.id == rows.first?.reviewID)
    }

    // MARK: - The Awards page

    @Test("One grid: held newest first, then silhouettes in the set's order, the 6 hidden until earned")
    func grid() async {
        let me = InMemoryAwards(awards: [nil: [
            Self.held(.dishes1, days: 0), Self.held(.dishes10, days: 15), Self.held(.dishes25, days: 34)
        ]])
        let store = AwardsStore(userID: nil, awards: me)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.earned.map(\.award) == [.dishes25, .dishes10, .dishes1])
        let cells = store.cells
        #expect(cells.count == 18, "nineteen less the secret 6")
        #expect(cells.prefix(3).map(\.id) == [.dishes25, .dishes10, .dishes1])
        #expect(cells.dropFirst(3).first?.id == .dishes50)
        #expect(cells.contains { $0.id == .first6 } == false)
        #expect(store.daysAfterFirstDish(store.earned[0], calendar: Self.utc) == 34)
        #expect(store.daysAfterFirstDish(store.earned[2], calendar: Self.utc) == nil, "not a count")
    }

    @Test("The 6 shows once earned")
    func six() async {
        let store = AwardsStore(userID: nil, awards: InMemoryAwards(awards: [nil: [Self.held(.first6, days: 1)]]))
        await store.loadIfNeeded()
        #expect(store.cells.count == 19)
        #expect(store.cells.first?.id == .first6)
    }

    @Test("Somebody else's awards are theirs; a failed read draws no band")
    func others() async {
        let bob = UUID()
        let awards = InMemoryAwards(awards: [bob: [Self.held(.first5, days: 2)], nil: []])
        let store = AwardsStore(userID: bob, awards: awards)
        await store.loadIfNeeded()
        #expect(store.earned.map(\.award) == [.first5])

        let failing = AwardsStore(userID: nil, awards: Failing())
        await failing.loadIfNeeded()
        #expect(failing.phase == .unavailable)
    }

    // MARK: - The takeover

    @Test("Every unseen award in one takeover, newest first, marked seen as it comes up, never twice")
    func takeover() async {
        let me = InMemoryAwards(awards: [nil: [
            Self.held(.dishes1, days: 0), Self.held(.dishes10, days: 15),
            Self.held(.dishes25, days: 34, seen: false), Self.held(.first5, days: 20, seen: false)
        ]])
        let takeover = AwardTakeover(awards: me)
        await takeover.check()
        #expect(takeover.showing.map(\.award) == [.dishes25, .first5])
        #expect(me.markedSeen.count == 1)
        #expect(Set(me.markedSeen.first.flatMap { $0 } ?? []) == [.dishes25, .first5])
        #expect(takeover.daysAfterFirstDish(takeover.showing[0], calendar: Self.utc) == 34)

        await takeover.check()
        #expect(me.markedSeen.count == 1, "not re-read while it is up")
        takeover.finish()
        await takeover.check()
        #expect(takeover.showing.isEmpty, "nothing unseen is left")
    }

    @Test("Nothing unseen, or a failed read: no takeover")
    func quietTakeover() async {
        let none = AwardTakeover(awards: InMemoryAwards(awards: [nil: [Self.held(.dishes1, days: 0)]]))
        await none.check()
        #expect(none.showing.isEmpty)
        let failing = AwardTakeover(awards: Failing())
        await failing.check()
        #expect(failing.showing.isEmpty)
    }

    // MARK: - The dishes behind an opened award

    @Test("Lines page oldest first until a short page")
    func linePages() async {
        let all = (0..<130).map { index in
            AwardLine(
                reviewID: UUID(), entryID: nil, dishID: UUID(), dishName: "Dish \(index)",
                createdAt: Self.t0.addingTimeInterval(Double(index) * 60)
            )
        }
        let awards = InMemoryAwards(lines: [.dishes250: all])
        let store = AwardLinesStore(userID: nil, award: .dishes250, awards: awards)
        await store.loadIfNeeded()
        #expect(store.lines.count == 60)
        await store.loadMore(after: store.lines[10])
        #expect(store.lines.count == 60, "only from the last row")
        await store.loadMore(after: store.lines[59])
        await store.loadMore(after: store.lines[119])
        #expect(store.lines.map(\.dishName) == all.map(\.dishName))
        #expect(store.isExhausted)
    }

    // MARK: - Events

    @Test("Award events, pinned")
    func events() {
        #expect(AwardEvents.takeoverShown(award: .dishes25, count: 2).name == "award_takeover_shown")
        #expect(AwardEvents.takeoverShown(award: .dishes25, count: 2).parameters
            == ["award": "dishes_25", "count": "2"])
        #expect(AwardEvents.opened(award: .first5, source: .awardsPage, isMe: false).parameters
            == ["award": "first_5", "source": "awards_page", "is_me": "false"])
        #expect(AwardEvents.shared(award: .firstDessert, source: .takeover).name == "award_shared")
        #expect(AwardEvents.pageViewed(isMe: true, earned: 7).parameters == ["is_me": "true", "earned": "7"])
    }

    // MARK: - Support

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private final class Failing: AwardsReading, TestFake, @unchecked Sendable {
        struct Nope: Error {}
        func awards(of userID: UUID?) async throws -> [EarnedAward] { throw Nope() }
        func markSeen(_ awards: [PlateAward]?) async throws { throw Nope() }
        func lines(
            of userID: UUID?, award: PlateAward, after cursor: PageCursor?, limit: Int
        ) async throws -> [AwardLine] {
            throw Nope()
        }
    }
}
