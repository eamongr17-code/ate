import AteKit
import SwiftUI

/// **The Diet key opening** (round 5, Eamon picked B — "a nicer transition"). The Diet disc is where
/// the codes come from: the other keys dissolve where they are, and the five codes spring out of the
/// disc leftwards, nearest first, as if the key opened. Back (or a code going in) folds them into it
/// again. With Reduce Motion it is a plain fade.
struct ComposerDietUnfold<Keys: View, Back: View, Code: View>: View {
    let isChoosingDiet: Bool
    let keys: Keys
    let back: Back
    let code: (DietTag) -> Code

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var spring: Animation { .spring(duration: 0.46, bounce: 0.28) }

    var body: some View {
        ZStack(alignment: .leading) {
            if isChoosingDiet == false {
                keys.transition(reduceMotion ? .opacity : Self.keysDissolving)
            }
            HStack(spacing: ComposerToolbar.gap) {
                if isChoosingDiet {
                    back.transition(reduceMotion ? .opacity : Self.backFading)
                }
                ForEach(Array(DietTag.allCases.enumerated()), id: \.element) { position, tag in
                    if isChoosingDiet {
                        code(tag).transition(unfolding(position))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .ateAnimation(Self.spring, value: isChoosingDiet)
    }

    private static var keysDissolving: AnyTransition { .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)) }
    private static var backFading: AnyTransition { .opacity.animation(.easeOut(duration: 0.2).delay(0.12)) }

    /// Out of the disc at the right edge: the further a code travels, the later it leaves.
    private func unfolding(_ position: Int) -> AnyTransition {
        guard reduceMotion == false else { return .opacity }
        let fromEnd = DietTag.allCases.count - position
        let travel = CGFloat(fromEnd) * 52 + 90
        let folded = AnyTransition.offset(x: travel).combined(with: .scale(scale: 0.3)).combined(with: .opacity)
        return .asymmetric(
            insertion: folded.animation(Self.spring.delay(0.035 * Double(fromEnd - 1))),
            removal: folded.animation(Animation.spring(duration: 0.3, bounce: 0).delay(0.02 * Double(position)))
        )
    }
}
