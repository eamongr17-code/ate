import SwiftUI

/// **The four motion moments**, plus the loaders' paper feed, and no others (`docs/DESIGN.md`): the
/// receipt prints in, the caret blinks, the voice button pulses, the score numerals roll.
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
    /// **The paper feed** (round 6, Eamon): every skeleton on screen — and a receipt still printing
    /// (`SummaryLoading`) — carries one soft highlight that crosses the screen left to right, 1.6s a
    /// pass. It is timed off the clock and placed in screen space, so every placeholder shares the
    /// same band and nothing pulses out of step. Drawn by ``AteSkeletonSweep``.
    static let sweepPeriod: Double = 1.6
    /// The band's width, and the distance it travels past each edge so it enters and leaves unseen.
    static let sweepBand: CGFloat = 220
    /// How far a pass travels: wider than any iPhone, so the band is off screen between passes.
    static let sweepTravel: CGFloat = 480
    /// How far a bar fades toward the paper under the band's peak — the old breath's 45%, travelling.
    static let sweepDepth: Double = 0.6
    /// The Summary's receipt settling from where it prints (`top:160`) to where it rests (`top:180`)
    /// once the lines are in — the print's own ease, over the same 0.6s.
    static let settle = Animation.easeOut(duration: printDuration)
    /// A page that loads in pieces filling in once, over its still skeleton (round 4: no blinking,
    /// no shimmer — a still placeholder, then one fade). Gate with ``SwiftUICore/View/ateAnimation(_:value:)``.
    static let fillIn = Animation.easeOut(duration: 0.3)
}

extension View {
    /// Applies an animation only when Reduce Motion is off. Reads the environment, so it reacts to
    /// the setting changing while the app is open.
    func ateAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(AteAnimationModifier(animation: animation, value: value))
    }

    /// The receipt's print-in. **Share's alone**: the entry is a page now, and a page does not print
    /// — the one moment of theatre belongs to the artefact, at the moment it is made. With Reduce
    /// Motion on, the receipt is simply there.
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
