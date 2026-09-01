import UIKit

/// The log flow's haptics, in one place so the vocabulary stays small and consistent.
///
/// Three sensations, each with a meaning: a *selection tick* per half-step crossed while scrubbing,
/// a *soft impact* when a rating settles, and a *medium impact* when the sitting is posted. Nothing
/// else vibrates — a phone that buzzes at everything says nothing.
///
/// One shared selection generator, kept alive across a scrub: `prepare()` on a fresh instance every
/// frame would warm the Taptic Engine repeatedly and tick late.
@MainActor
enum LogHaptics {
    private static let selection = UISelectionFeedbackGenerator()

    /// Call at the start of a scrub, not per change.
    static func prepareSelection() {
        selection.prepare()
    }

    /// §2.3: one tick per half-step crossing.
    static func selectionChanged() {
        selection.selectionChanged()
    }

    /// §2.3: on release, only when the value changed.
    static func ratingSettled() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// §5.1: the Post tap.
    static func posted() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
