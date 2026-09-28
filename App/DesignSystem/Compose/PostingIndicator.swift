import SwiftUI

/// **What "Posting…" looks like while the composer holds** (round 6, Eamon: "some sort of subtle
/// loading state … right now it feels like the screen has frozen up"). Two answers, on the device,
/// until he picks: `-ate-r6-posting A|B` (Debug and Beta; A without the argument). The composer is
/// frozen behind both (``ComposerScreen/isFrozen``).
enum ComposerPostingStyle: String {
    /// **A — the pill prints.** The pill's own label steps its three dots in, one at a time, like a
    /// printer working, and starts again. Nothing else on the screen changes.
    case pill = "A"
    /// **B — the page waits.** The writing dims a touch, and a thin coral print head sweeps back and
    /// forth under the header.
    case page = "B"

    static var current: ComposerPostingStyle {
        #if DEBUG || BETA
        UserDefaults.standard.string(forKey: "ate-r6-posting").flatMap(Self.init(rawValue:)) ?? .pill
        #else
        .pill
        #endif
    }
}

/// A: "Posting" with its three dots printing in. The dots are always laid out, only their opacity
/// steps, so the pill never changes width while it works. Still, with all three dots, under Reduce
/// Motion.
struct PostingDotsLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.step)) { context in
            let shown = reduceMotion ? 3 : Self.dots(at: context.date)
            HStack(spacing: 0) {
                Text("Posting")
                ForEach(0..<3, id: \.self) { index in
                    Text(".").opacity(index < shown ? 1 : 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Posting…")
    }

    /// 0, 1, 2, 3 dots, then round again.
    private static func dots(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / step) % 4
    }

    private static let step: TimeInterval = 0.32
}

/// B: the print head. A short coral bar sweeping back and forth along a 2pt line, easing at each
/// end. Nothing under Reduce Motion (the dim alone says it).
struct PostingPrinterLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if reduceMotion == false {
                TimelineView(.animation) { context in
                    let width = proxy.size.width * Self.fraction
                    Capsule()
                        .fill(AteColor.coral)
                        .frame(width: width, height: Self.height)
                        .offset(x: (proxy.size.width - width) * Self.position(at: context.date))
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    /// 0 → 1 → 0 over one period, eased at both ends.
    private static func position(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return CGFloat(0.5 - 0.5 * cos(phase * 2 * .pi))
    }

    private static let period: TimeInterval = 1.8
    private static let fraction: CGFloat = 0.26
    private static let height: CGFloat = 2
}

/// B's dim: the writing under a very light ink veil. Takes no touches of its own.
struct PostingVeil: View {
    var body: some View {
        AteColor.ink.opacity(Self.strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let strength: Double = 0.05
}
