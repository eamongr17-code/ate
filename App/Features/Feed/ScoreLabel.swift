import AteKit
import SwiftUI

/// A score as half-stars plus its number.
///
/// It takes an **optional** ``Rating`` on purpose. A posted review always has a score (the column is
/// NOT NULL and the type can't hold an illegal value), but an *unrated dish* is a real product state
/// — `dish_stats.score IS NULL`, the "want to try" case — and it must read `–/5`, never `0/5`. Zero
/// stars and "no rating yet" are different claims about the world; conflating them is the legacy
/// bug this type exists to prevent.
struct ScoreLabel: View {
    let rating: Rating?

    private static let starCount = 5

    var body: some View {
        HStack(spacing: Theme.Spacing.hairline) {
            ForEach(0..<Self.starCount, id: \.self) { index in
                Image(systemName: symbol(at: index))
                    .foregroundStyle(rating == nil ? Theme.Color.textTertiary : Theme.Color.accent)
            }
            Text(numberText)
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.leading, Theme.Spacing.tight)
        }
        .font(Theme.Text.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func symbol(at index: Int) -> String {
        guard let rating else { return "star" }
        if index < rating.filledStars { return "star.fill" }
        if index == rating.filledStars && rating.hasHalfStar { return "star.leadinghalf.filled" }
        return "star"
    }

    private var numberText: String {
        guard let rating else { return "–/5" }  // en dash: an absent rating, not a zero
        return "\(rating.value.formatted(.number.precision(.fractionLength(0...1))))/5"
    }

    private var accessibilityLabel: String {
        guard let rating else { return "Not rated yet" }
        return "\(rating.value.formatted(.number.precision(.fractionLength(0...1)))) out of 5"
    }
}

#Preview("Scores") {
    VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
        ScoreLabel(rating: Rating(exactly: 5))
        ScoreLabel(rating: Rating(exactly: 4.5))
        ScoreLabel(rating: Rating(exactly: 0.5))
        ScoreLabel(rating: nil)
    }
    .padding(Theme.Spacing.comfortable)
}
