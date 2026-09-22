import SwiftUI

/// **The four motion moments**, and no others (`docs/DESIGN.md`): the receipt prints in, the caret
/// blinks, the voice button pulses, the score numerals roll.
///
/// Every one is gated on Reduce Motion. The gate lives here rather than at each call site, so a new
/// animation cannot be added without going through a function that already respects the setting.
enum AteMotion {
    /// The receipt printing: slide 24pt down and fade, 0.6s. The one moment in the app that is a
    /// small piece of theatre — the app's promise, made visible.
    static let printDuration: Double = 0.6
    static let printOffset: CGFloat = -24

    static let print = Animation.easeOut(duration: printDuration)
    /// The numerals rolling under a finger on the star slider.
    static let scoreRoll = Animation.snappy(duration: 0.18)
    /// A caret blink, and the voice pulse.
    static let caretBlink: Double = 1.0
    static let voicePulse: Double = 1.6
}

extension View {
    /// Applies an animation only when Reduce Motion is off. Reads the environment, so it reacts to
    /// the setting changing while the app is open.
    func ateAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(AteAnimationModifier(animation: animation, value: value))
    }

    /// The receipt's print-in: the whole reason the entry screen feels like a machine finishing a
    /// job. With Reduce Motion on, the receipt is simply there.
    func atePrintsIn(_ isPresented: Bool) -> some View {
        modifier(AtePrintModifier(isPresented: isPresented))
    }
}

private struct AteAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct AtePrintModifier: ViewModifier {
    let isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isPresented || reduceMotion ? 1 : 0)
            .offset(y: isPresented || reduceMotion ? 0 : AteMotion.printOffset)
            .animation(reduceMotion ? nil : AteMotion.print, value: isPresented)
    }
}

/// A blinking caret — used by the composer's placeholder state, where there is no real text view
/// caret to show yet. Honours Reduce Motion by simply standing still.
struct AteCaret: View {
    var height: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(AteColor.coral)
            .frame(width: 2, height: height)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                guard reduceMotion == false else { return }
                withAnimation(.linear(duration: AteMotion.caretBlink).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }
}
