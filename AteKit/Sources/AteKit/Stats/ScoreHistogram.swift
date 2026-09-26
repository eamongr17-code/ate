import Foundation

/// **One bar of `score_histogram`** — a half-step, and what the viewer put there.
///
/// Two counts, and they are genuinely different questions: `dishCount` is *distinct dishes* scored
/// at this value (the number the Ratings screen prints, "36 dishes") and `reviewCount` is how many
/// times they handed it out — two sittings of the same pasta are one dish and two reviews.
public struct ScoreBucket: Sendable, Hashable, Codable, Identifiable {
    /// 0.5 … 5.0. Always a half-step; the server generates the series, so it never lands elsewhere.
    public let score: Double
    public let dishCount: Int
    public let reviewCount: Int

    /// The half-step index, 1…10. Keyed on an `Int` rather than the `Double` so two bars can never
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

/// **Your ratings, as ten bars.**
///
/// The RPC returns all ten half-steps with their zeros included, precisely so the client never has
/// to invent a bucket — but a client that *trusts* that and gets nine rows draws a chart with a hole
/// in it, so this normalises on the way in: exactly ten buckets, ascending, missing ones at zero and
/// anything off the half-step grid dropped.
public struct ScoreHistogram: Sendable, Hashable {
    /// The ten scores a bar can stand for, ascending.
    public static let scores: [Double] = (1...10).map { Double($0) / 2 }

    /// Ten buckets, 0.5 → 5.0.
    public let buckets: [ScoreBucket]

    public init(_ rows: [ScoreBucket]) {
        var byStep: [Int: ScoreBucket] = [:]
        for row in rows {
            let step = Self.halfSteps(row.score)
            guard (1...10).contains(step) else { continue }
            byStep[step] = row
        }
        buckets = (1...10).map { step in
            byStep[step] ?? ScoreBucket(score: Double(step) / 2, dishCount: 0, reviewCount: 0)
        }
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
        guard (1...10).contains(step) else {
            return ScoreBucket(score: score, dishCount: 0, reviewCount: 0)
        }
        return buckets[step - 1]
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

    /// 1…10 for 0.5…5.0. Rounded, because the wire value is a decimal string parsed into a binary
    /// double and 4.5 is only exactly 4.5 by luck.
    public static func halfSteps(_ score: Double) -> Int { Int((score * 2).rounded()) }

    /// The nearest half-step, clamped into the scale. What a bar tap hands on.
    public static func snapped(_ score: Double) -> Double {
        Double(min(10, max(1, halfSteps(score)))) / 2
    }
}
