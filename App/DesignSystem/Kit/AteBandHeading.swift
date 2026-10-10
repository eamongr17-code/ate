import AteKit
import SwiftUI

/// **A band's heading on a page** — "Your ratings", "Your top dishes": one line in the control face.
/// (The small one; a Feed section's 28pt heading is `AteSectionHeading`.)
/// With an action it is a link to the band's own page, the chevron at the far end and the whole line
/// a 44pt target.
struct AteBandHeading: View {
    let title: String
    var identifier: String?
    var action: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        if let action {
            Button(action: action) {
                HStack(spacing: AteMetrics.snug) {
                    label
                    Spacer(minLength: 0)
                    AteIcon.chevron.view(size: AteBandHeadingMetrics.chevron)
                        .foregroundStyle(palette.muted)
                }
                .frame(minHeight: AteMetrics.hit)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The line keeps its own height in the band; the target hangs past it.
            .padding(.vertical, -AteBandHeadingMetrics.hitBleed)
            .accessibilityIdentifier(identifier ?? "section.\(title)")
        } else {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var label: some View {
        Text(title)
            .ateText(.control)
            .foregroundStyle(palette.fg)
            .accessibilityAddTraits(.isHeader)
    }
}

/// **A Ratings group's head** — the score at 30, its five stars, and how many dishes sit there at
/// the other end of the row, never parted by a dot.
struct AteScoreGroupHeader: View {
    let score: Double
    let dishCount: Int

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteScoreGroupHeaderMetrics.gap) {
            Text(ScoreFormat.halfStep(score))
                .ateText(.ratingsScore)
                .foregroundStyle(palette.fg)
                .monospacedDigit()
            HStack(spacing: AteMetrics.hairspace) {
                let stars = ScoreFormat.stars(for: score)
                ForEach(0..<AteScoreGroupHeaderMetrics.stars, id: \.self) { index in
                    AteStar(
                        fill: Self.fill(index, full: stars.full, half: stars.half),
                        side: AteScoreGroupHeaderMetrics.star,
                        lineWidth: AteScoreGroupHeaderMetrics.starLine
                    )
                }
            }
            Spacer(minLength: AteMetrics.snug)
            Text(ScoreFormat.dishCount(dishCount))
                .ateText(.meta)
                .foregroundStyle(palette.muted)
        }
        .padding(.top, AteMetrics.tight)
        .padding(.bottom, AteMetrics.snug)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private static func fill(_ index: Int, full: Int, half: Bool) -> Double {
        if index < full { return 1 }
        if index == full, half { return 0.5 }
        return 0
    }
}

/// A group's head before it has arrived.
struct AteScoreGroupHeaderSkeleton: View {
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        AteSkeletonBar(
            width: AteScoreGroupHeaderMetrics.skeletonWidth,
            height: AteScoreGroupHeaderMetrics.skeletonHeight,
            palette: palette
        )
        .padding(.top, AteMetrics.tight)
        .padding(.bottom, AteMetrics.snug)
        .ateSkeletonSweep(breathes)
        .accessibilityHidden(true)
    }
}

enum AteBandHeadingMetrics {
    static let chevron: CGFloat = 15
    /// (44 − the line's 18) / 2: the link's target reaches past the line it sits on.
    static let hitBleed: CGFloat = 13
}

enum AteScoreGroupHeaderMetrics {
    static let gap: CGFloat = 10
    static let stars = 5
    static let star: CGFloat = 20
    static let starLine: CGFloat = 1.5
    static let skeletonWidth: CGFloat = 170
    static let skeletonHeight: CGFloat = 30
    /// Groups are parted by the page's section gap.
    static let groupGap: CGFloat = AteMetrics.section
}
