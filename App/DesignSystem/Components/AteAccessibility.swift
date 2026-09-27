import SwiftUI

extension View {
    /// Hides this view from VoiceOver when `isHidden`, and otherwise leaves it — and everything in it
    /// — to its own choices.
    ///
    /// Use this, never `accessibilityHidden(<Bool>)`: an outer `accessibilityHidden(false)` is not a
    /// no-op, it overrode the `accessibilityHidden(true)` of views inside it (round 5: the minimised
    /// tab bar's hidden tabs stayed reachable). SwiftLint enforces it (`accessibility_hidden_bool`).
    @ViewBuilder
    func ateAccessibilityHidden(_ isHidden: Bool) -> some View {
        if isHidden {
            accessibilityHidden(true)
        } else {
            self
        }
    }
}
