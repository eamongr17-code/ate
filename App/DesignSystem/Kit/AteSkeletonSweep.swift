import SwiftUI

/// **The paper feed** — the one motion a placeholder makes (``AteMotion/sweepPeriod``). A soft band
/// in the paper's own colour crosses the subtree, drawn *atop* what is there (`sourceAtop`): it
/// tints only pixels the skeleton drew, so a bar fades toward the paper as the band passes and the
/// paper itself, already that colour, shows nothing. The band's place comes from the clock and the screen, never from the
/// view, so a column of rows reads as one sheet feeding through rather than each row on its own beat.
///
/// Reduce Motion, or `isOn` false: the placeholder is still.
struct AteSkeletonSweep: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isOn, reduceMotion == false {
            content
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        TimelineView(.animation) { context in
                            AteSkeletonSweepBand()
                                .frame(width: AteMotion.sweepBand, height: frame.height)
                                .offset(x: Self.bandX(at: context.date) - frame.minX)
                        }
                    }
                    .blendMode(.sourceAtop)
                    .allowsHitTesting(false)
                }
                .compositingGroup()
        } else {
            content
        }
    }

    /// The band's leading edge in screen space: from one band off the left edge to past the right.
    static func bandX(at date: Date) -> CGFloat {
        let period = AteMotion.sweepPeriod
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -AteMotion.sweepBand + CGFloat(phase) * (AteMotion.sweepTravel + AteMotion.sweepBand)
    }
}

/// The band: clear, then the paper's colour at ``AteMotion/sweepDepth``, then clear.
private struct AteSkeletonSweepBand: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: AteColor.skeletonSweep.opacity(AteMotion.sweepDepth), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

extension View {
    /// Runs the paper feed (``AteSkeletonSweep``) over this placeholder while `isOn`.
    func ateSkeletonSweep(_ isOn: Bool = true) -> some View {
        modifier(AteSkeletonSweep(isOn: isOn))
    }
}
