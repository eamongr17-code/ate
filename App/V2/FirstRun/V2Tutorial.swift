import SwiftUI

/// **Tutorial** (Settings) — the onboarding's tutorial on its own, over everything: no handle,
/// no photo ask, no start screen. Next on the last card, or Skip, closes it.
struct V2Tutorial: View {
    /// The receipt's signature on the cards.
    let handle: String
    /// Left the cards: the furthest step seen (1–5), and whether Skip did it.
    let onDone: (_ reached: Int, _ skipped: Bool) -> Void

    var body: some View {
        NavigationStack {
            OnboardingCards(onDone: onDone, handle: handle)
                .ateGround()
        }
    }
}
