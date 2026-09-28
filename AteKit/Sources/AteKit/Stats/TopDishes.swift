import Foundation

/// **"Your top dishes"** (round 6, renamed from "Your 5.0s") — the four best things you have eaten,
/// by your own score.
///
/// The rename changes what the set means, so the set changed with it:
/// - ranked by score, best first — a secret 6 leads (it is a real 6), then the 5.0s, then the 4.5s,
///   then the 4.0s; newest first within a score, as `dishes_by_score` pages them;
/// - never below 4.0: "top" does not reach down to a middling dish just to fill four tiles;
/// - one tile per dish, however many times it was scored.
///
/// A person with nothing at 4.0 or above has no section at all (design rule 1).
public enum TopDishes {
    public static let limit = 4
    public static let floor = 4.0
    /// The scores to read when the chart could not be: every one a top dish can have.
    static let allScores: [Double] = [ScoreHistogram.six, 5, 4.5, 4]

    /// The scores worth asking for, best first: the bars at or above the floor that hold a dish.
    public static func scores(in histogram: ScoreHistogram?) -> [Double] {
        guard let histogram, histogram.isEmpty == false else { return histogram == nil ? allScores : [] }
        return histogram.buckets
            .filter { $0.score >= floor && $0.dishCount > 0 }
            .map(\.score)
            .sorted(by: >)
    }

    /// Reads score by score, best first, until four dishes are in hand.
    public static func read(
        scores: [Double],
        page: @Sendable (Double) async throws -> [ScoredDish]
    ) async -> [ScoredDish]? {
        var picked: [ScoredDish] = []
        var seen = Set<UUID>()
        var answered = false
        for score in scores where picked.count < limit {
            guard let rows = try? await page(score) else { continue }
            answered = true
            for dish in rows where picked.count < limit && seen.insert(dish.dishID).inserted {
                picked.append(dish)
            }
        }
        return answered || scores.isEmpty ? picked : nil
    }
}
