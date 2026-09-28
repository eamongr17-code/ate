import SwiftUI

/// **What "Posting…" looks like while the composer holds** (round 6, Eamon's pick: "some sort of
/// subtle loading state … right now it feels like the screen has frozen up"). The pill's own label
/// steps its three dots in, one at a time, like a printer working, and starts again. Nothing else on
/// the screen changes; the composer is frozen behind it (``ComposerScreen/isFrozen``).
///
/// The dots are always laid out, only their opacity steps, so the pill never changes width while it
/// works. Still, with all three dots, under Reduce Motion.
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
    static func dots(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / step) % 4
    }

    static let step: TimeInterval = 0.32
}
