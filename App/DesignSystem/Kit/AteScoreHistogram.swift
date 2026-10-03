import AteKit
import SwiftUI

/// **Your ratings, as ten bars** — the chart on You and on Ratings, one component so the two cannot
/// disagree about the shape of your own taste. An eleventh bar, the secret 6 in brick, is drawn once
/// one has been given (``ScoreHistogram/drawnScores``).
///
/// Butter, because butter is the colour a score is printed on everywhere else. The lit bar on
/// Ratings is ink (the contract keeps coral to the Share and Welcome grounds). A bucket nobody has
/// used is drawn as **nothing** — not a stub: a score is never inferred.
///
/// The `ScoreHistogramView` of the current build, with the lit bar re-coloured and each bar a button
/// that ticks the selection haptic.
struct AteScoreHistogram: View {
    let histogram: ScoreHistogram
    /// The lit bar, if any.
    var selected: Double?
    /// Tapping a bar. Bars with nothing behind them are not links.
    var onSelect: ((Double) -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: AteMetrics.snug) {
            HStack(alignment: .bottom, spacing: AteMetrics.tight) {
                ForEach(histogram.drawnScores, id: \.self) { score in
                    bar(score)
                }
            }
            .frame(height: AteScoreHistogramMetrics.height)
            scale
        }
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func bar(_ score: Double) -> some View {
        let count = histogram.dishCount(at: score)
        let isLit = selected.map { ScoreHistogram.halfSteps($0) == ScoreHistogram.halfSteps(score) } ?? false
        return Button {
            guard count > 0 else { return }
            onSelect?(score)
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AteScoreHistogramBar()
                    .fill(isLit ? palette.fg : Self.fill(for: score))
                    .frame(height: height(for: score))
            }
            .frame(maxWidth: .infinity)
            .frame(height: AteScoreHistogramMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onSelect != nil && count > 0)
        .accessibilityLabel("\(ScoreFormat.halfStep(score)): \(ScoreFormat.dishCount(count))")
        .accessibilityAddTraits(isLit ? .isSelected : [])
        .accessibilityHidden(count == 0)
    }

    private func height(for score: Double) -> CGFloat {
        let fraction = histogram.fraction(at: score)
        guard fraction > 0 else { return 0 }
        return max(AteScoreHistogramMetrics.shortest, (AteScoreHistogramMetrics.tallest * fraction).rounded())
    }

    /// `1 2 3 4 5` under the whole steps — one column per bar, so a label sits exactly under its bar.
    private var scale: some View {
        HStack(spacing: AteMetrics.tight) {
            ForEach(histogram.drawnScores, id: \.self) { score in
                Text(score.rounded() == score ? score.formatted(.number.precision(.fractionLength(0))) : "")
                    .ateText(.scaleLabel)
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// Butter for every score, brick for the secret 6.
    static func fill(for score: Double) -> Color {
        let isSix = ScoreHistogram.halfSteps(score) == ScoreHistogram.halfSteps(ScoreHistogram.six)
        return isSix ? ScoreStyle.sixthStar : AteColor.scoreMark
    }
}

/// One bar: rounded at the top, square on the baseline.
struct AteScoreHistogramBar: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: AteScoreHistogramMetrics.radius,
            topTrailingRadius: AteScoreHistogramMetrics.radius,
            style: .continuous
        )
        .path(in: rect)
    }
}

/// **The chart before it has arrived** — ten still bars and the scale line's height, breathing.
struct AteScoreHistogramSkeleton: View {
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: AteMetrics.snug) {
            HStack(alignment: .bottom, spacing: AteMetrics.tight) {
                ForEach(Array(AteScoreHistogramMetrics.skeleton.enumerated()), id: \.offset) { _, height in
                    AteScoreHistogramBar()
                        .fill(palette.hairline)
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: AteScoreHistogramMetrics.height, alignment: .bottom)
            Color.clear.frame(height: AteScoreHistogramMetrics.scaleHeight)
        }
        .ateBreathing(breathes)
        .accessibilityHidden(true)
    }
}

enum AteScoreHistogramMetrics {
    /// `height:92px` for the bars, `gap:4px`.
    static let height: CGFloat = 92
    /// The tallest bar in that 92 — the chart breathes rather than filling its well.
    static let tallest: CGFloat = 88
    /// A bar that exists but is dwarfed still has to be visible.
    static let shortest: CGFloat = 4
    static let radius: CGFloat = 6
    /// The scale's one line.
    static let scaleHeight: CGFloat = 13
    /// The skeleton's still shape.
    static let skeleton: [CGFloat] = [12, 16, 22, 30, 40, 52, 64, 76, 60, 34]
}
