import AteKit
import SwiftUI

/// **The dish hero** — the dish's photos as the tilted pair the dish page opens on (`Dish.dc.html`):
/// two 150 squircles lapped 44, the dish hero's own angles. Absent when the dish has no photo — a
/// grey placeholder would be a picture of nothing. ``placeholder`` holds one photo's room while a
/// row that opened the page knew there were photos but not which.
struct AteDishHero: View {
    let photos: [AtePhoto]
    var onTap: ((Int) -> Void)?

    var body: some View {
        if photos.isEmpty == false {
            PhotoCluster(
                photos: photos,
                side: AteDishHeroMetrics.side,
                topPadding: AteDishHeroMetrics.top,
                bottomPadding: 0,
                overlap: AteDishHeroMetrics.overlap,
                angles: AtePhotoAngles.dishHero,
                onTap: onTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One photo's still room.
    static var placeholder: some View {
        AteDishHeroPlaceholder()
    }
}

private struct AteDishHeroPlaceholder: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: AteDishHeroMetrics.side), style: .continuous)
            .fill(palette.hairline)
            .frame(width: AteDishHeroMetrics.side, height: AteDishHeroMetrics.side)
            .padding(.top, AteDishHeroMetrics.top)
            .padding(.leading, AteDishHeroMetrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateBreathing()
            .accessibilityHidden(true)
    }
}

enum AteDishHeroMetrics {
    static let side: CGFloat = 150
    static let overlap: CGFloat = 44
    static let top: CGFloat = 6
    /// The cluster's own 6 leading inset, so a still tile sits where the first photo will.
    static let inset: CGFloat = 6
}

/// **A dish's aggregate** — the number at 64 to one decimal, and beside it five stars filled to the
/// nearest half, over how many people and the dish's diet chips. An unrated dish prints no number
/// and no stars: the people line alone, or nothing (scores are never inferred).
struct AteDishAggregate: View {
    let score: Double?
    let peopleCount: Int
    var tags: [DietTag] = []

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: AteDishAggregateMetrics.gap) {
            if let score {
                // Fixed digits: the secret 6.0 is exactly as wide as any 5.
                Text(ScoreFormat.average(score))
                    .ateText(.dishScore)
                    .foregroundStyle(palette.fg)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel("Rated \(ScoreFormat.average(score))")
                VStack(alignment: .leading, spacing: AteDishAggregateMetrics.lineGap) {
                    AteStarRow(score: score)
                    meta
                }
            } else {
                meta
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var meta: some View {
        if peopleCount > 0 || tags.isEmpty == false {
            HStack(spacing: AteMetrics.snug) {
                if peopleCount > 0 {
                    HStack(spacing: AteMetrics.tight) {
                        AteIcon.feed.view(size: AteDishAggregateMetrics.peopleIcon)
                        Text(peopleCount == 1 ? "1 person" : "\(peopleCount) people")
                            .ateText(.meta)
                    }
                    .foregroundStyle(palette.muted)
                    .accessibilityElement(children: .combine)
                }
                AteDietChips(tags: tags, onGround: true)
                    .accessibilityIdentifier("dish.tags")
            }
        }
    }
}

/// Five stars filled by what an aggregate earns — whole, half or empty, all at full strength.
struct AteStarRow: View {
    let score: Double
    var side: CGFloat = AteDishAggregateMetrics.star

    var body: some View {
        let stars = ScoreFormat.stars(for: score)
        HStack(spacing: AteDishAggregateMetrics.starGap) {
            ForEach(0..<5, id: \.self) { index in
                AteStar(
                    fill: index < stars.full ? 1 : (index == stars.full && stars.half ? 0.5 : 0),
                    side: side,
                    lineWidth: AteDishAggregateMetrics.starStroke
                )
            }
        }
        .accessibilityHidden(true)
    }
}

enum AteDishAggregateMetrics {
    /// `gap:14px`; the stars over the people line `gap:6px`; five 20pt stars 2 apart.
    static let gap: CGFloat = 14
    static let lineGap: CGFloat = 6
    static let star: CGFloat = 20
    static let starGap: CGFloat = 2
    static let starStroke: CGFloat = 1.5
    static let peopleIcon: CGFloat = 14
}

/// **Chips that flow** — a place's facts under its name (its average, how many people, cuisine,
/// suburb: only the facts we hold), and a dish's "More to explore" tags, each a door to its dishes.
/// The existing ``AteChip`` on ``AteFlow``: they wrap onto a second line rather than truncate.
struct AteChipFlow: View {
    struct Chip: Identifiable {
        let id: String
        var icon: AteIcon?
        let title: String
        var accessibilityLabel: String?
        var action: (() -> Void)?
    }

    let chips: [Chip]
    /// The explore chips are taller and roomier than a place's facts.
    var isExplore = false

    var body: some View {
        AteFlow(spacing: isExplore ? AteChipFlowMetrics.exploreGap : AteChipFlowMetrics.factGap) {
            ForEach(chips) { chip in
                AteChip(
                    icon: chip.icon,
                    title: chip.title,
                    height: isExplore ? AteChipFlowMetrics.exploreHeight : AteMetrics.chipHeight,
                    iconSize: AteChipFlowMetrics.icon,
                    sidePadding: isExplore ? AteChipFlowMetrics.explorePadding : AteMetrics.regular,
                    textStyle: isExplore ? .exploreChip : .controlSmall,
                    action: chip.action
                )
                .accessibilityLabel(chip.accessibilityLabel ?? chip.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chips before they arrive: one line of still capsules at the chips' own height.
struct AteChipFlowSkeleton: View {
    var isExplore = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: isExplore ? AteChipFlowMetrics.exploreGap : AteChipFlowMetrics.factGap) {
            ForEach(AteChipFlowMetrics.skeletonWidths, id: \.self) { width in
                Capsule()
                    .fill(palette.hairline)
                    .frame(width: width,
                           height: isExplore ? AteChipFlowMetrics.exploreHeight : AteMetrics.chipHeight)
            }
        }
        .ateBreathing()
        .accessibilityHidden(true)
    }
}

enum AteChipFlowMetrics {
    /// A place's facts `gap:6px`; the explore chips `gap:8px`, `height:34px; padding:0 14px`.
    static let factGap: CGFloat = 6
    static let exploreGap: CGFloat = 8
    static let exploreHeight: CGFloat = 34
    static let explorePadding: CGFloat = 14
    static let icon: CGFloat = 14
    static let skeletonWidths: [CGFloat] = [64, 58, 82]
}
