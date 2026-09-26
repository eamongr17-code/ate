#if DEBUG
import Foundation

/// **The You tab in memory** — previews and `-ate-preview-data`, with no backend at all.
///
/// It carries the artboards' own numbers (`You`, `Ratings`, `Recap`), so a screenshot taken against
/// it and the design can be held side by side. Debug only, in both directions: the type does not
/// exist in a Beta or Release binary.
public final class InMemoryStatsService: StatsReading, @unchecked Sendable {

    private let viewer: ViewerProfile
    private let buckets: [ScoreBucket]
    private let dishes: [ScoredDish]
    private let statements: [MonthlyStatement]

    public init(
        viewer: ViewerProfile = .preview,
        buckets: [ScoreBucket] = InMemoryStatsService.seededBuckets,
        dishes: [ScoredDish] = InMemoryStatsService.seededDishes,
        statements: [MonthlyStatement] = InMemoryStatsService.seededStatements
    ) {
        self.viewer = viewer
        self.buckets = buckets
        self.dishes = dishes
        self.statements = statements
    }

    public func viewerID() async throws -> UUID { viewer.id }

    public func summary(userID: UUID) async throws -> ProfileSummary {
        ProfileSummary(
            userID: viewer.id,
            username: viewer.username,
            name: viewer.name,
            city: viewer.city,
            orders: 142,
            places: 61,
            dishes: 318,
            scored: ScoreHistogram(buckets).total,
            avgScore: 4.1,
            isMe: true
        )
    }

    public func histogram(userID: UUID) async throws -> ScoreHistogram {
        ScoreHistogram(buckets)
    }

    public func dishes(
        userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
    ) async throws -> Page<ScoredDish> {
        let wanted = ScoreHistogram.halfSteps(score)
        var rows = dishes
            .filter { ScoreHistogram.halfSteps($0.score) == wanted }
            .sorted { ($0.createdAt, $0.reviewID.uuidString) > ($1.createdAt, $1.reviewID.uuidString) }
        if let cursor {
            rows = rows.filter {
                ($0.createdAt, $0.reviewID.uuidString) < (cursor.createdAt, cursor.id.uuidString)
            }
        }
        let limit = max(1, pageSize)
        return Page(items: Array(rows.prefix(limit)), requestedLimit: limit)
    }

    public func months(
        userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
    ) async throws -> [StatementMonthSummary] {
        var rows = statements.sorted { $0.month > $1.month }
        if let cursor { rows = rows.filter { $0.month < cursor } }
        return rows
            .prefix(max(1, limit))
            .map { StatementMonthSummary(month: $0.month, orders: $0.orders) }
    }

    public func statement(
        userID: UUID,
        month: StatementMonth,
        timeZone: TimeZone
    ) async throws -> MonthlyStatement {
        statements.first { $0.month == month } ?? MonthlyStatement(month: month)
    }
}

public extension InMemoryStatsService {
    /// `You.dc.html`'s own bars, read off the artboard's pixel heights.
    static let seededBuckets: [ScoreBucket] = [
        ScoreBucket(score: 0.5, dishCount: 1, reviewCount: 1),
        ScoreBucket(score: 1.0, dishCount: 1, reviewCount: 1),
        ScoreBucket(score: 1.5, dishCount: 3, reviewCount: 3),
        ScoreBucket(score: 2.0, dishCount: 5, reviewCount: 5),
        ScoreBucket(score: 2.5, dishCount: 9, reviewCount: 9),
        ScoreBucket(score: 3.0, dishCount: 14, reviewCount: 15),
        ScoreBucket(score: 3.5, dishCount: 25, reviewCount: 27),
        ScoreBucket(score: 4.0, dishCount: 40, reviewCount: 44),
        ScoreBucket(score: 4.5, dishCount: 36, reviewCount: 39),
        ScoreBucket(score: 5.0, dishCount: 16, reviewCount: 16)
    ]

    /// `Ratings.dc.html`'s five rows, plus the four `You` prints as "Your 5.0s".
    static let seededDishes: [ScoredDish] = {
        let covers = ["ragu", "sushi", "pizza", "cake", "burger", "penne", "prawn", "tiramisu"]
        var index = 0
        func dish(
            _ name: String, _ place: String, _ score: Double, _ daysAgo: Int
        ) -> ScoredDish {
            defer { index += 1 }
            return ScoredDish(
                reviewID: UUID(),
                dishID: UUID(),
                dishName: name,
                restaurantID: UUID(),
                restaurantName: place,
                score: score,
                createdAt: Date(timeIntervalSince1970: 1_789_000_000 - Double(daysAgo) * 86_400),
                coverURL: "asset://\(covers[index % covers.count])"
            )
        }
        return [
            dish("Tagliatelle al ragù", "Tipo 00", 4.5, 0),
            dish("Cheeseburger", "Butchers Diner", 4.5, 17),
            dish("Margherita", "400 Gradi", 4.5, 22),
            dish("Raspberry cake", "Beatrix", 4.5, 29),
            dish("Penne al ragù", "Di Stasio", 4.5, 41),
            dish("Cheeseburger", "Butchers Diner", 5.0, 3),
            dish("Salmon roll", "Kisumé", 5.0, 11),
            dish("Margherita", "400 Gradi", 5.0, 26),
            dish("Raspberry cake", "Beatrix", 5.0, 33),
            // Below the artboard's bar, so the one-page list has more than two groups to scroll
            // through — and one from last year, whose date carries its year.
            dish("Prawn toast", "Hochi Mama", 4.0, 5),
            dish("Salmon roll", "Kisumé", 4.0, 38),
            dish("Penne alla vodka", "Di Stasio", 3.5, 12),
            dish("Tiramisu", "Tipo 00", 3.0, 300)
        ]
    }()

    /// `Recap.dc.html`, and one month behind it so a page turn has somewhere to go.
    static let seededStatements: [MonthlyStatement] = [
        MonthlyStatement(
            month: StatementMonth(year: 2026, month: 9),
            username: "eamon",
            orders: 9, places: 6, newPlaces: 4, dishes: 14, stars: 57.5, average: 4.1,
            topDishes: [
                .init(dishID: UUID(), dishName: "Tagliatelle al ragù",
                      restaurantName: "Tipo 00", score: 4.5),
                .init(dishID: UUID(), dishName: "Kingfish sashimi",
                      restaurantName: "Chin Chin", score: 4.5),
                .init(dishID: UUID(), dishName: "Pork bun",
                      restaurantName: "Supernormal", score: 4.5)
            ],
            mostOrdered: .init(dishName: "Pasta", count: 4),
            mostVisited: .init(restaurantName: "Tipo 00", count: 2)
        ),
        MonthlyStatement(
            month: StatementMonth(year: 2026, month: 8),
            username: "eamon",
            orders: 7, places: 5, newPlaces: 2, dishes: 11, stars: 42, average: 3.8,
            topDishes: [
                .init(dishID: UUID(), dishName: "Lobster spaghetti",
                      restaurantName: "Gimlet", score: 5),
                .init(dishID: UUID(), dishName: "Prawn betel leaf",
                      restaurantName: "Chin Chin", score: 4.5)
            ],
            mostOrdered: .init(dishName: "Oysters", count: 3),
            mostVisited: .init(restaurantName: "Beatrix", count: 2)
        )
    ]
}
#endif
