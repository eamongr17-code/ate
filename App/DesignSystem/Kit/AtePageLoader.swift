import SwiftUI

/// **The page loader — the tally** (round 6, Eamon). For the rare wait with no shape to skeleton:
/// a small receipt, on the receipt's own torn paper, whose dish lines write themselves in one after
/// another — the mark, its leader, its score — then the totals land, and the tally starts again.
///
/// The lines are ink marks, never words: a receipt with dishes on it would read as somebody's entry,
/// and a receipt only ever prints what was eaten. The wordmark is there from the first frame.
///
/// It costs nothing to show: drawn shapes off one clock, no images or data to fetch. It waits
/// ``AtePageLoaderMetrics/delay`` before it appears, so a quick load never flashes it. Reduce
/// Motion: the tally sits written in full, still.
struct AtePageLoader: View {
    @State private var isShown = false
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isShown {
                receipt
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: AtePageLoaderMetrics.delay)
            start = .now
            withAnimation(AteMotion.fillIn) { isShown = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }

    private var receipt: some View {
        Group {
            if reduceMotion {
                AteTallySlip(written: { _ in 1 }, totals: 1)
            } else {
                TimelineView(.animation) { context in
                    let clock = AteTally(elapsed: context.date.timeIntervalSince(start))
                    AteTallySlip(written: clock.written(line:), totals: clock.totals)
                        .opacity(clock.ink)
                }
            }
        }
        .frame(width: AtePageLoaderMetrics.width)
    }
}

/// The tally's clock: which part of each line is written, at a moment in the cycle. Pure, so the
/// rhythm can be read without running it.
struct AteTally {
    static let lines = 3
    /// One cycle: write, hold, fade.
    static let cycle: Double = 3.2
    /// Each line starts this long after the one above it…
    static let stagger: Double = 0.45
    /// …and takes this long to write.
    static let write: Double = 0.6
    /// The totals land once the last line is written.
    static let totalsAt: Double = Double(lines - 1) * stagger + write
    /// The ink fades over the cycle's last stretch, so it can start again on blank paper.
    static let fadeFrom: Double = 2.8

    let elapsed: Double

    private var time: Double { elapsed.truncatingRemainder(dividingBy: Self.cycle) }

    /// How much of `line` is written, 0…1.
    func written(line: Int) -> Double {
        let begun = time - Double(line) * Self.stagger
        return min(max(begun / Self.write, 0), 1)
    }

    /// The totals band, 0…1.
    var totals: Double { min(max((time - Self.totalsAt) / 0.25, 0), 1) }

    /// The ink as a whole, fading out at the cycle's end.
    var ink: Double { time < Self.fadeFrom ? 1 : max(0, 1 - (time - Self.fadeFrom) / (Self.cycle - Self.fadeFrom)) }
}

/// The slip itself: the receipt's anatomy at a small size — dish lines, a dashed rule, the totals,
/// the wordmark — on torn paper.
private struct AteTallySlip: View {
    let written: (Int) -> Double
    let totals: Double

    /// Each line's mark and score widths, so the column does not read as a grid.
    private static let marks: [(name: CGFloat, score: CGFloat)] = [(78, 22), (54, 22), (66, 22)]

    var body: some View {
        VStack(spacing: AteMetrics.snug + 2) {
            VStack(spacing: AteMetrics.snug) {
                ForEach(0..<AteTally.lines, id: \.self) { line in
                    AteTallyLine(name: Self.marks[line].name, score: Self.marks[line].score)
                        .mask(alignment: .leading) {
                            GeometryReader { proxy in
                                Rectangle().frame(width: proxy.size.width * written(line))
                            }
                        }
                }
            }
            .padding(.top, AteMetrics.hairspace)
            AteDashedRule()
            HStack {
                AtePageLoaderMark(width: 40)
                Spacer(minLength: AteMetrics.snug)
                AtePageLoaderMark(width: 34)
            }
            .opacity(totals)
            HStack {
                Spacer(minLength: 0)
                AteWordmark(height: AteMetrics.wordmarkFooter)
            }
        }
        .padding(.top, AteMetrics.loose)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: AteMetrics.receiptTop)
        .accessibilityHidden(true)
    }
}

/// One written line: the dish's mark, the receipt's leader, the score's mark.
private struct AteTallyLine: View {
    let name: CGFloat
    let score: CGFloat

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            AtePageLoaderMark(width: name, height: AtePageLoaderMetrics.lineMark)
            AteDotLeader()
            AtePageLoaderMark(width: score, height: AtePageLoaderMetrics.lineMark)
        }
    }
}

/// A written mark — the slip's ink, softened, at a line's height.
private struct AtePageLoaderMark: View {
    let width: CGFloat
    var height: CGFloat = AtePageLoaderMetrics.labelMark

    var body: some View {
        Capsule()
            .fill(AtePalette.slip.fg.opacity(AtePageLoaderMetrics.inkOpacity))
            .frame(width: width, height: height)
    }
}

enum AtePageLoaderMetrics {
    /// The slip's width: a receipt, small.
    static let width: CGFloat = 200
    /// How long a wait must run before the tally appears.
    static let delay: Duration = .milliseconds(400)
    /// A dish line's mark, at the lead dish's x-height.
    static let lineMark: CGFloat = 10
    /// A totals mark, at the fine print's.
    static let labelMark: CGFloat = 7
    /// Ink, a touch softer than print so it never reads as words.
    static let inkOpacity: Double = 0.78
}

#if DEBUG
#Preview("Page loader") {
    AtePageLoader()
        .ateGround()
}
#endif
