import Foundation

/// **Each slip tilts its own way** (Eamon, 20 Oct: every single photo sat at the same −5°). A slip's
/// cluster takes its angles from the entry's id rather than from a fixed table, so the journal reads
/// as a pile of different snaps while one entry still looks the same every time it scrolls past.
///
/// Derived from the UUID's bytes, never `hashValue` (seeded per launch, it would reshuffle on every
/// open). Neighbours alternate sides so overlapping photos fan out rather than stack, and every
/// angle stays between ``minimum`` and ``maximum`` either side of zero: never near-straight, which
/// reads as a mistake, and never past the table's own 6°, which the cluster's air already covers.
public enum PhotoTilt {
    public static let minimum = 2.0
    public static let maximum = 6.0
    /// Angles land on half-degree steps: 2, 2.5 … 6.
    static let step = 0.5

    /// `count` angles in degrees for the entry `seed`, one per photo position.
    public static func angles(seed: UUID, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var state = fnv1a(seed)
        let steps = Int(((maximum - minimum) / step).rounded())
        let lean: Double = next(&state) & 1 == 0 ? 1 : -1
        return (0..<count).map { position in
            let magnitude = minimum + Double(Int(next(&state) % UInt64(steps + 1))) * step
            return (position.isMultiple(of: 2) ? lean : -lean) * magnitude
        }
    }

    private static func fnv1a(_ id: UUID) -> UInt64 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    /// SplitMix64: one well-mixed number per call from a running state.
    private static func next(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
