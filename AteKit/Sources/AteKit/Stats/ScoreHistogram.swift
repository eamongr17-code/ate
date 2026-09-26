import Foundation

/// **One bar of `score_histogram`** — a half-step, and what the viewer put there.
///
/// Two counts, and they are genuinely different questions: `dishCount` is *distinct dishes* scored
/// at this value (the number the Ratings screen prints, "36 dishes") and `reviewCount` is how many
/// times they handed it out — two sittings of the same pasta are one dish and two reviews.
public struct ScoreBucket: Sendable, Hashable, Codable, Identifiable {
    /// 0.5 … 5.0 in half-steps, and the secret 6.0. The server generates the series, so it never
    /// lands elsewhere.
    public let score: Double
    public let dishCount: Int
    public let reviewCount: Int

    /// The half-step index, 1…10, or 12 for a 6. Keyed on an `Int` rather than the `Double` so two bars can never
    /// compare unequal because of a binary fraction.
    public var id: Int { ScoreHistogram.halfSteps(score) }

    public init(score: Double, dishCount: Int, reviewCount: Int) {
        self.score = score
        self.dishCount = dishCount
        self.reviewCount = reviewCount
    }

    enum CodingKeys: String, CodingKey {
        case score
        case dishCount = "dish_count"
        case reviewCount = "review_count"
    }
}

/// **Your ratings, as ten bars — and an eleventh for a 6.**
///
/// The RPC returns every bucket with its zeros included, precisely so the client never has to
/// invent one — but a client that *trusts* that and gets nine rows draws a chart with a hole in it,
/// so this normalises on the way in: exactly eleven buckets, ascending, missing ones at zero and
/// anything off the grid dropped.
///
/// **The secret 6** (round 4): a 6 exists only when the composer marked one, and it counts as a real
/// 6 everywhere. The chart gains its bar — but only draws it once there is something in it
/// (``drawnScores``), so the scale a new person sees is still one to five.
public struct ScoreHistogram: Sendable, Hashable {
    /// The eleven scores a bar can stand for, ascending: the half-steps to 5.0, then 6.0.
    public static let scores: [Double] = steps.map { Double($0) / 2 }

    /// Half-step indices on the scale: 1…10, and 12 for the 6. There is no 5.5.
    static let steps: [Int] = Array(1...10) + [sixStep]
    static let sixStep = 12
    /// The secret score.
    public static let six = 6.0

    /// Eleven buckets, 0.5 → 5.0, then 6.0.
    public let buckets: [ScoreBucket]

    public init(_ rows: [ScoreBucket]) {
        var byStep: [Int: ScoreBucket] = [:]
        for row in rows {
            let step = Self.halfSteps(row.score)
            guard Self.steps.contains(step) else { continue }
            byStep[step] = row
        }
        buckets = Self.steps.map { step in
            byStep[step] ?? ScoreBucket(score: Double(step) / 2, dishCount: 0, reviewCount: 0)
        }
    }

    /// The bars the chart draws: 0.5 → 5.0 always, and the 6 only once somebody has given one.
    public var drawnScores: [Double] {
        dishCount(at: Self.six) > 0 ? Self.scores : Array(Self.scores.dropLast())
    }

    /// Nothing scored yet — the first-day state, and the one where no bar is drawn at all.
    public static let empty = ScoreHistogram([])

    /// True when the viewer has never scored anything.
    public var isEmpty: Bool { buckets.allSatisfy { $0.dishCount == 0 } }

    /// The tallest bar's count. 0 when nothing is scored.
    public var peak: Int { buckets.map(\.dishCount).max() ?? 0 }

    /// Every dish the viewer has scored, counted once per score.
    public var total: Int { buckets.reduce(0) { $0 + $1.dishCount } }

    public func bucket(at score: Double) -> ScoreBucket {
        let step = Self.halfSteps(score)
        guard let index = Self.steps.firstIndex(of: step) else {
            return ScoreBucket(score: score, dishCount: 0, reviewCount: 0)
        }
        return buckets[index]
    }

    public func dishCount(at score: Double) -> Int { bucket(at: score).dishCount }

    /// How tall this bar is, as a fraction of the tallest. 0 for an empty bucket — a score nobody
    /// gave is drawn as nothing, not as a stub, because a stub reads as "one" (design rule 7: a
    /// score is never inferred).
    public func fraction(at score: Double) -> Double {
        let count = dishCount(at: score)
        guard count > 0, peak > 0 else { return 0 }
        return Double(count) / Double(peak)
    }

    /// Which bar "Your ratings ›" opens on: the fullest one, and the *higher* score when two tie.
    /// The artboard's own selection is illustrative, so the rule is ours — and a screen that opened
    /// on your emptiest score would be a screen that opened on nothing.
    public var busiestScore: Double? {
        guard isEmpty == false else { return nil }
        return buckets.max { left, right in
            (left.dishCount, left.score) < (right.dishCount, right.score)
        }?.score
    }

    /// The highest score with anything behind it — the first group on `Ratings`, which is where
    /// "Your ratings ›" opens the page: at its top, with nothing scrolled past.
    public var highestScore: Double? {
        buckets.last { $0.dishCount > 0 }?.score
    }

    /// 1…10 for 0.5…5.0, 12 for 6.0. Rounded, because the wire value is a decimal string parsed into a binary
    /// double and 4.5 is only exactly 4.5 by luck.
    public static func halfSteps(_ score: Double) -> Int { Int((score * 2).rounded()) }

    /// The nearest bar, clamped into the scale. What a bar tap hands on. A 6 is a 6; anything
    /// between 5.0 and 6.0 is a 5.0 — there is no 5.5 to land on.
    public static func snapped(_ score: Double) -> Double {
        let step = halfSteps(score)
        if step >= sixStep { return six }
        return Double(min(10, max(1, step))) / 2
    }
}
