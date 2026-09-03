import AteKit
import SwiftUI

/// **The shared score atom** (§3.3): a half-star row plus a monospaced numeral, or the null state.
///
/// `nil` is not zero. An unrated dish (`dish_stats.score IS NULL`) is a meaningful product state —
/// "nobody's ordered this yet" — and renders `–/5` in tertiary text. Rendering it as `0/5` would be a
/// claim nobody made, and is the legacy bug this atom exists to make impossible.
///
/// It takes a `Double?` rather than a `Rating?` because it renders *aggregates* too (4.3 is not a
/// half-step). The Feed's own `ScoreLabel` is gone with `FeedRow` (§2): the feed renders ``DishCard``
/// now, so this is the only score mark in the app.
struct ScoreMark: View {
    let score: Double?
    /// Optional trailing `(12)`. §3.3: detail and menu contexts only — never on a compose card,
    /// where the only number that matters is the one you're about to give it.
    var reviewCount: Int?
    var size: Size = .card

    enum Size {
        case card
        case compact

        var numeral: Font {
            switch self {
            case .card: Theme.Text.scoreNumeral
            case .compact: Theme.Text.rowScore
            }
        }

        var star: CGFloat {
            switch self {
            case .card: Theme.Size.star * 1.4
            case .compact: Theme.Size.star
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
            StarRow(score: score, starSize: size.star)
            Text(ScoreFormat.outOfFive(score))
                .font(size.numeral)
                .foregroundStyle(score == nil ? Theme.Color.textTertiary : Theme.Color.textPrimary)
            if let reviewCount, score != nil {
                Text("(\(reviewCount))")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard score != nil else { return "Not rated" }
        let base = "\(ScoreFormat.outOfFive(score))"
        guard let reviewCount else { return base }
        return "\(base), \(ScoreFormat.reviewCount(reviewCount))"
    }
}

/// Five glyphs, filled to a score. Hidden from VoiceOver — whatever is next to it says the number.
struct StarRow: View {
    let score: Double?
    var starSize: CGFloat = Theme.Size.star
    /// Spread the glyphs evenly across the available width (§2.1). The rating gesture needs this:
    /// its ten zones are equal fifths of the track, so each star must own exactly one fifth of it.
    var spread = false

    var body: some View {
        let stars = ScoreFormat.stars(for: score)
        HStack(spacing: spread ? 0 : Theme.Spacing.tight) {
            ForEach(0..<5, id: \.self) { index in
                // Fixed cell: `star.leadinghalf.filled` is narrower than `star.fill`, and an
                // HStack hands out space from each glyph's own width — so without this every
                // half-step crossing re-spaces the whole row and the stars jump under the finger.
                Image(systemName: Self.symbol(at: index, stars: stars))
                    .font(.system(size: starSize))
                    .frame(width: Self.cellWidth(for: starSize), height: starSize)
                    .frame(maxWidth: spread ? .infinity : nil)
            }
        }
        .foregroundStyle(score == nil ? Theme.Color.ratingEmpty : Theme.Color.ratingFilled)
        .accessibilityHidden(true)
    }

    static func symbol(at index: Int, stars: (full: Int, half: Bool)) -> String {
        if index < stars.full { return "star.fill" }
        if index == stars.full, stars.half { return "star.leadinghalf.filled" }
        return "star"
    }

    /// One cell fits the widest of the three star glyphs at this point size, so swapping glyphs
    /// never changes layout. SF's star is ~1.1× as wide as its point size.
    static func cellWidth(for starSize: CGFloat) -> CGFloat { (starSize * 1.1).rounded(.up) }
}

#Preview("Score marks") {
    VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
        ScoreMark(score: 4.5)
        ScoreMark(score: 4.3, reviewCount: 12)
        ScoreMark(score: nil)
        ScoreMark(score: 3.0, size: .compact)
    }
    .padding(Theme.Spacing.comfortable)
}
