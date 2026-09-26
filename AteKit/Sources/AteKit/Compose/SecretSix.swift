import Foundation

/// **The secret 6** (round 4), as a state machine — the part of the gesture that is about distance
/// and time, which no screenshot shows.
///
/// On the score slider a finger that drags **past** 5.0 meets slight resistance (the track follows it
/// on a rubber band). Held out there for ``holdDuration`` the charge builds — a haptic that grows —
/// and then a sixth star appears. Nothing is written about it anywhere: no label, no hint.
///
/// The rules, each tested:
/// - past the end means more than ``threshold`` points beyond the track's last pixel — a finger
///   that merely *reaches* 5.0 and rests there is scoring a 5.0, never a 6;
/// - the charge starts when the finger crosses out there, and any retreat inside cancels it;
/// - it unlocks only once ``holdDuration`` has passed with the finger still out there;
/// - once unlocked, it holds while the finger stays near the end, and a drag well back inside
///   (``release``) gives it up — the slider is the ordinary slider again.
public struct SecretSix: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// On the track, or at its end: an ordinary score.
        case idle
        /// Past the end and holding, since `since` (seconds, any monotonic clock).
        case charging(since: TimeInterval)
        /// The sixth star is out.
        case unlocked
    }

    /// Points past the track's end before a drag counts as "past 5.0".
    public static let threshold: Double = 12
    /// How long the finger holds out there.
    public static let holdDuration: TimeInterval = 1.0
    /// How far back inside the track an unlocked 6 lets go — a zone and a half, so a finger that
    /// wobbles at the end never flickers between 5.0 and 6.
    public static let releaseZones: Double = 1.5
    /// The rubber band: the most the track travels, however far the finger goes.
    public static let maxStretch: Double = 14

    public private(set) var phase: Phase = .idle

    public init() {}

    public var isUnlocked: Bool { phase == .unlocked }

    /// How far past the end of a track of `trackWidth` a finger at `x` is (negative: inside it).
    public static func overshoot(x fingerX: Double, trackWidth: Double) -> Double { fingerX - trackWidth }

    /// The rubber band: how far the stars follow a finger `overshoot` points past the end. Zero on
    /// the track; past it, a curve that starts at a third of the finger's travel and flattens out
    /// at ``maxStretch`` — resistance, never a wall.
    public static func stretch(overshoot: Double) -> Double {
        guard overshoot > 0 else { return 0 }
        let give = overshoot / 3
        return maxStretch * give / (give + maxStretch)
    }

    /// The finger moved. Returns true when the phase changed.
    @discardableResult
    public mutating func move(x fingerX: Double, trackWidth: Double, at time: TimeInterval) -> Bool {
        guard trackWidth > 0 else { return false }
        let past = Self.overshoot(x: fingerX, trackWidth: trackWidth)
        let before = phase
        switch phase {
        case .idle:
            if past > Self.threshold { phase = .charging(since: time) }
        case .charging:
            if past <= Self.threshold { phase = .idle }
        case .unlocked:
            let zone = trackWidth / Double(RatingTrack.zoneCount)
            if past < -zone * Self.releaseZones { phase = .idle }
        }
        return phase != before
    }

    /// Time passed with the finger where it was. Returns the charge, 0…1, while charging (1 the
    /// moment it unlocks), `nil` otherwise.
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Double? {
        guard case .charging(let since) = phase else { return nil }
        let progress = min(1, max(0, (time - since) / Self.holdDuration))
        if progress >= 1 { phase = .unlocked }
        return progress
    }

    /// The finger lifted (or the drag was cancelled). An unlocked 6 stays the score; a charge that
    /// never finished is dropped.
    public mutating func lift() {
        if case .charging = phase { phase = .idle }
    }

    /// The slider reopened on a pill: a pill already holding a 6 opens unlocked.
    public mutating func reset(to rating: Rating?) {
        phase = rating == .blownAway ? .unlocked : .idle
    }

    /// The score the gesture means: the 6 once unlocked, otherwise what the track says.
    public func rating(onTrack rating: Rating) -> Rating {
        isUnlocked ? .blownAway : rating
    }
}
