import Foundation

/// **A score range** — the one score filter, shared by the Journal, Saved and Search. Two ends on the
/// score track: the half-steps from 0.5 to 5.0, then the secret **6** one stop past them (the Rating
/// chip's two-thumb slider, whose presets include "5.0s" and "6s only").
///
/// The rules, each tested:
/// - the whole track is no filter at all — an unscored entry still shows (design rule 7: an empty
///   score slot is not a number, so only a *narrowed* range leaves it out);
/// - any narrowing leaves the unscored out, even with the bottom end on 0.5;
/// - the top end on **6** is open, so no ceiling is sent; a top end on 5.0 is a real ceiling, and a 6
///   is above it (the secret 6 counts as a real 6);
/// - both ends snap to the track's stops and never cross.
public struct ScoreBand: Hashable, Sendable {
    public static let floor: Double = 0.5
    /// The top of the ordinary scale.
    public static let topScore: Double = 5.0
    /// The secret 6 — the track's last stop, one past 5.0.
    public static let six: Double = 6
    public static let ceiling: Double = six
    public static let step: Double = 0.5
    /// The track, in order: 0.5 … 5.0 in halves, then 6. Eleven stops.
    public static let values: [Double] = Array(stride(from: floor, through: topScore, by: step)) + [six]
    public static var stops: Int { values.count }

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

    /// What goes on the wire as the maximum: nothing while the top end is on 6 (open).
    public var maxScore: Double? { upper >= Self.ceiling ? nil : upper }

    /// The chip and the sheet: "4.0+" with an open top, "3.0–4.5" otherwise, the two presets by
    /// their own names, `nil` for the whole track.
    public var title: String? {
        guard isAll == false else { return nil }
        if let preset, preset != .any, preset.isNamed { return preset.title }
        if upper >= Self.ceiling { return ScoreFormat.halfStep(lower) + "+" }
        if lower == upper { return ScoreFormat.halfStep(lower) }
        return ScoreFormat.halfStep(lower) + "–" + ScoreFormat.halfStep(upper)
    }

    /// The sheet's readout beside its title: "4.0 and up", "Any".
    public var summary: String {
        guard isAll == false else { return "Any" }
        if upper >= Self.ceiling, lower < Self.six { return ScoreFormat.halfStep(lower) + " and up" }
        return title ?? "Any"
    }

    /// Whether a score is inside. `nil` (unscored) is inside only the whole track.
    public func contains(_ score: Double?) -> Bool {
        guard isAll == false else { return true }
        guard let score else { return false }
        if score < lower { return false }
        if let maxScore, score > maxScore { return false }
        return true
    }

    // MARK: - The presets

    /// The sheet's quick choices under the slider.
    public enum Preset: String, CaseIterable, Sendable {
        case any, threePlus, fourPlus, fives, sixes

        public var title: String {
            switch self {
            case .any: "Any"
            case .threePlus: "3.0+"
            case .fourPlus: "4.0+"
            case .fives: "5.0s"
            case .sixes: "6s only"
            }
        }

        public var band: ScoreBand {
            switch self {
            case .any: .all
            case .threePlus: ScoreBand(lower: 3, upper: ScoreBand.ceiling)
            case .fourPlus: ScoreBand(lower: 4, upper: ScoreBand.ceiling)
            case .fives: ScoreBand(lower: ScoreBand.topScore, upper: ScoreBand.topScore)
            case .sixes: ScoreBand(lower: ScoreBand.six, upper: ScoreBand.six)
            }
        }

        /// Printed by name on a chip — the two that are not a plain "x+".
        var isNamed: Bool { self == .fives || self == .sixes }
    }

    /// Which preset this band is, if it is one.
    public var preset: Preset? { Preset.allCases.first { $0.band == self } }

    // MARK: - The track's arithmetic

    /// The nearest stop on the track (a tie goes up).
    public static func snap(_ value: Double) -> Double {
        values[index(of: value)]
    }

    /// The stop nearest `value`, 0…10.
    public static func index(of value: Double) -> Int {
        var best = 0
        for (index, stop) in values.enumerated() where abs(stop - value) <= abs(values[best] - value) {
            best = index
        }
        return best
    }

    /// The value at `fraction` (0…1) of the track's length — the stops are evenly spaced.
    public static func value(atFraction fraction: Double) -> Double {
        let clamped = Swift.min(Swift.max(fraction, 0), 1)
        return values[Int((clamped * Double(stops - 1)).rounded())]
    }

    /// Where a value sits along the track, 0…1.
    public static func fraction(of value: Double) -> Double {
        Double(index(of: value)) / Double(stops - 1)
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
