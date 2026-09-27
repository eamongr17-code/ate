import Foundation

/// **A score range** — the one score filter (round 5, Eamon: "they should just allow a range
/// setting"). Two ends on the half-step track from 0.5 to 5.0, shared by the Journal, Saved and
/// Search.
///
/// The rules, each tested:
/// - the whole track is no filter at all — an unscored entry still shows (design rule 7: an empty
///   score slot is not a number, so only a *narrowed* range leaves it out);
/// - any narrowing leaves the unscored out, even with the bottom end on 0.5;
/// - the top end on 5.0 is **open**: the secret 6 is a real 6 (round 4) and it clears "5.0 and up",
///   so no ceiling is sent;
/// - both ends snap to half-steps and never cross.
public struct ScoreBand: Hashable, Sendable {
    public static let floor: Double = 0.5
    public static let ceiling: Double = 5.0
    public static let step: Double = 0.5
    /// Half-steps across the track: 0.5 … 5.0 is ten stops, nine gaps.
    public static let stops = Int((ceiling - floor) / step) + 1

    public let lower: Double
    public let upper: Double

    public static let all = ScoreBand(lower: floor, upper: ceiling)

    public init(lower: Double, upper: Double) {
        let low = Self.snap(lower)
        let high = Self.snap(upper)
        self.lower = min(low, high)
        self.upper = max(low, high)
    }

    /// The band a query's two optional ends describe — absent ends are the track's own ends.
    public init(minScore: Double?, maxScore: Double?) {
        self.init(lower: minScore ?? Self.floor, upper: maxScore ?? Self.ceiling)
    }

    public var isAll: Bool { lower <= Self.floor && upper >= Self.ceiling }

    /// What goes on the wire as the minimum: nothing for the whole track, the bottom end otherwise
    /// (0.5 included — it is what leaves the unscored out).
    public var minScore: Double? { isAll ? nil : lower }

    /// What goes on the wire as the maximum: nothing while the top end is on 5.0 (open, so a 6
    /// clears it).
    public var maxScore: Double? { upper >= Self.ceiling ? nil : upper }

    /// The pill: "4.0+" with an open top, "3.0–4.5" otherwise, `nil` for the whole track.
    public var title: String? {
        guard isAll == false else { return nil }
        if upper >= Self.ceiling { return ScoreFormat.halfStep(lower) + "+" }
        if lower == upper { return ScoreFormat.halfStep(lower) }
        return ScoreFormat.halfStep(lower) + "–" + ScoreFormat.halfStep(upper)
    }

    /// Whether a score is inside. `nil` (unscored) is inside only the whole track; a 6 is inside any
    /// band whose top is open.
    public func contains(_ score: Double?) -> Bool {
        guard isAll == false else { return true }
        guard let score else { return false }
        if score < lower { return false }
        if let maxScore, score > maxScore { return false }
        return true
    }

    // MARK: - The track's arithmetic

    /// The nearest half-step on the track.
    public static func snap(_ value: Double) -> Double {
        let clamped = Swift.min(Swift.max(value, floor), ceiling)
        return (clamped / step).rounded() * step
    }

    /// The value at `fraction` (0…1) of the track's length.
    public static func value(atFraction fraction: Double) -> Double {
        snap(floor + Swift.min(Swift.max(fraction, 0), 1) * (ceiling - floor))
    }

    /// Where a value sits along the track, 0…1.
    public static func fraction(of value: Double) -> Double {
        (snap(value) - floor) / (ceiling - floor)
    }

    /// The band with one end moved to `value`; an end dragged past the other stops on it.
    public func moving(_ end: End, to value: Double) -> ScoreBand {
        switch end {
        case .lower: ScoreBand(lower: Swift.min(Self.snap(value), upper), upper: upper)
        case .upper: ScoreBand(lower: lower, upper: Swift.max(Self.snap(value), lower))
        }
    }

    public enum End: Hashable, Sendable { case lower, upper }

    /// Which end a touch at `value` should pick up: the nearer one; on a tie (the ends together),
    /// the one that has room to move that way.
    public func nearerEnd(to value: Double) -> End {
        let toLower = abs(value - lower)
        let toUpper = abs(value - upper)
        if toLower == toUpper { return value < lower ? .lower : .upper }
        return toLower < toUpper ? .lower : .upper
    }
}
