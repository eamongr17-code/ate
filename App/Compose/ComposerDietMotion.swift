import AteKit
import SwiftUI

// Round 5 exploration (`-ate-r5-diet A|B`): how the Diet key opens its row of codes, and how the
// ordinary keys come back. Today's is a 0.15s cross-fade. With Reduce Motion both are a fade.

/// **A — slide across.** The toolbar moves over like a page: the ordinary keys slide off to the left
/// as the codes arrive from the right edge, one a beat after another. Back reverses it.
struct ComposerDietSlide<Keys: View, Back: View, Code: View>: View {
    let isChoosingDiet: Bool
    let keys: Keys
    let back: Back
    let code: (DietTag) -> Code

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var spring: Animation { .spring(duration: 0.4, bounce: 0.14) }

    var body: some View {
        ZStack(alignment: .leading) {
            if isChoosingDiet == false {
                keys.transition(reduceMotion ? .opacity : Self.keysLeaving)
            }
            HStack(spacing: 6) {
                if isChoosingDiet {
                    back.transition(reduceMotion ? .opacity : Self.backArriving)
                }
                ForEach(Array(DietTag.allCases.enumerated()), id: \.element) { position, tag in
                    if isChoosingDiet {
                        code(tag).transition(arrival(position))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .ateAnimation(Self.spring, value: isChoosingDiet)
    }

    private static var keysLeaving: AnyTransition { .move(edge: .leading).combined(with: .opacity) }
    private static var backArriving: AnyTransition { .offset(x: 120).combined(with: .opacity) }

    /// Each code comes in from the right a beat after the one before; they leave together.
    private func arrival(_ position: Int) -> AnyTransition {
        guard reduceMotion == false else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 140 + CGFloat(position) * 14).combined(with: .opacity)
                .animation(Self.spring.delay(0.025 * Double(position))),
            removal: .offset(x: 160).combined(with: .opacity)
        )
    }
}

/// **B — unfold from the key.** The Diet disc is where the codes come from: the other keys dissolve
/// where they are, and the five codes spring out of the disc's corner leftwards, nearest first, as
/// if the key opened. Back folds them into it again.
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
            HStack(spacing: 6) {
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
