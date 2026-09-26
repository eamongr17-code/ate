import Foundation

/// **The paper's bottom edge** — `EdgeFinal.dc.html`, edge B, symmetrical (Eamon, 2026-09-26).
///
/// A soft scallop rather than a zigzag, and the part that can be quietly wrong is the arithmetic:
/// a fixed 12pt period left a half-scallop at one end of every card, so the edge read as cut off
/// rather than torn. The period is **fitted to the width** instead — `P = W / round(W / 12)` — so a
/// whole number of scallops always fits and both ends land on the same valley. Pure and UI-free so
/// the numbers the board names (366 → 30 × 12.2, 350 → 29, 286 → 24) are asserted, not eyeballed.
public enum WaveEdge {
    /// What the period aims for before it is fitted.
    public static let targetPeriod: Double = 12
    /// The strip drawn under the paper, in the paper's bottom tone.
    public static let height: Double = 4
    /// How far below the paper's bottom the edge is at a valley, and at a crest (3pt amplitude).
    public static let valley: Double = 0.6
    public static let crest: Double = 3.6

    /// How many whole scallops fit a width. Never zero: a sliver still gets one.
    ///
    /// A half rounds to even, which is what the board's own numbers say: 366 / 12 is exactly 30.5,
    /// and the spec prints 30 scallops of 12.2 for it, not 31.
    public static func periodCount(forWidth width: Double) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width / targetPeriod).rounded(.toNearestOrEven)))
    }

    /// The fitted period — the board's `background-repeat: round`.
    public static func period(forWidth width: Double) -> Double {
        guard width > 0 else { return targetPeriod }
        return width / Double(periodCount(forWidth: width))
    }

    /// `y(x) = 2.1 − 1.5·cos(2πx / P)`, measured down from the paper's bottom. A valley at every
    /// period boundary and a crest in the middle, so the row is mirror-symmetric end to end.
    public static func depth(atX position: Double, width: Double) -> Double {
        let mid = (valley + crest) / 2
        let amplitude = (crest - valley) / 2
        return mid - amplitude * cos(2 * Double.pi * position / period(forWidth: width))
    }
}
