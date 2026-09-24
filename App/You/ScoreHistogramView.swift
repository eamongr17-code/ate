import AteKit
import SwiftUI

/// **Your ratings, as ten bars** — the chart on `You` and on `Ratings`, one component so the two
/// cannot disagree about the shape of your own taste.
///
/// Butter, because butter is the colour a score is printed on everywhere else (design rule 5:
/// colour is punctuation). The selected bar goes coral, which is the only difference between the
/// chart on the tab and the chart on the page.
///
/// A bucket nobody has used is drawn as **nothing** — not as a stub. Design rule 7 says a score is
/// never inferred, and a 4pt bar under an empty bucket reads as "you gave one of those".
struct ScoreHistogramView: View {
    let histogram: ScoreHistogram
    /// The lit bar, if any.
    var selected: Double?
    /// Tapping a bar. Bars with nothing behind them are not links.
    var onSelect: ((Double) -> Void)?

    /// `height:92px` for the bars, `gap:4px`.
    private static let height: CGFloat = 92
    /// The artboard's tallest bar in that 92 — the chart breathes rather than filling its well.
    private static let tallest: CGFloat = 88
    /// A bar that exists but is dwarfed still has to be visible.
    private static let shortest: CGFloat = 4

    var body: some View {
        VStack(spacing: AteMetrics.snug) {
            bars
            scale
        }
        .accessibilityElement(children: .contain)
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: AteMetrics.tight) {
            ForEach(ScoreHistogram.scores, id: \.self) { score in
                bar(score)
            }
        }
        .frame(height: Self.height)
    }

    @ViewBuilder
    private func bar(_ score: Double) -> some View {
        let count = histogram.dishCount(at: score)
        let isSelected = selected.map { ScoreHistogram.halfSteps($0) == ScoreHistogram.halfSteps(score) } ?? false
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 6,
            style: .continuous
        )
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            shape
                .fill(isSelected ? AteColor.coral : AteColor.butter)
                .frame(height: height(for: score))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .contentShape(.rect)
        .onTapGesture {
            guard count > 0 else { return }
            onSelect?(score)
        }
        .accessibilityElement()
        .accessibilityLabel("\(ScoreFormat.halfStep(score)): \(ScoreFormat.dishCount(count))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHidden(count == 0)
    }

    private func height(for score: Double) -> CGFloat {
        let fraction = histogram.fraction(at: score)
        guard fraction > 0 else { return 0 }
        return max(Self.shortest, (Self.tallest * fraction).rounded())
    }

    /// `1 2 3 4 5` under the whole steps — ten equal columns, five of them labelled, so a label sits
    /// exactly under its bar rather than between two.
    private var scale: some View {
        HStack(spacing: AteMetrics.tight) {
            ForEach(ScoreHistogram.scores, id: \.self) { score in
                Text(score.rounded() == score ? score.formatted(.number.precision(.fractionLength(0))) : "")
                    .ateText(.scaleLabel)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Histogram") {
    VStack(spacing: AteMetrics.section) {
        ScoreHistogramView(histogram: ScoreHistogram(InMemoryStatsService.seededBuckets))
        ScoreHistogramView(
            histogram: ScoreHistogram(InMemoryStatsService.seededBuckets),
            selected: 4.5
        )
        ScoreHistogramView(histogram: .empty)
    }
    .padding(AteMetrics.gutter)
    .frame(maxHeight: .infinity, alignment: .top)
    .ateGround()
}
#endif
