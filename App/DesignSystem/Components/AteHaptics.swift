import UIKit

/// The one place that asks the phone to make something felt. A *selection* generator, not an impact
/// one: a score crossing a half-step is a value changing, which is exactly what `selectionChanged`
/// means — and it is the lightest thing the Taptic Engine does, which matters when one scrub crosses
/// nine of them.
@MainActor
enum AteHaptics {
    private static let selection = UISelectionFeedbackGenerator()

    static func tick() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// A save landing. An *impact*, not a selection: a bookmark is a thing put on a shelf, and it is
    /// one tap rather than nine in a scrub, so it can afford to be felt.
    static func save() {
        key()
    }

    /// **A key pressed** — the Score, Place and Diet keys, a diet code, the `+`, and a bookmark (``save()``
    /// is this): one light impact, so the same kind of tap feels the same everywhere (round 4).
    static func key() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The secret 6 building under a held finger: taps that grow, `progress` 0…1.
    static func charge(_ progress: Double) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.25 + 0.75 * min(1, max(0, progress)))
    }

    /// …and the sixth star coming out.
    static func blownAway() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// …and the sixth star coming out locked: none left to give. One soft tap, no celebration.
    static func sixLocked() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// A key that had nothing to act on — the Diet key with no dish before the caret. The system's
    /// own error pattern, the lightest thing that says "not here" without a word of copy.
    static func refused() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// An entry saved — Done in the composer landing. The system's own success pattern.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
