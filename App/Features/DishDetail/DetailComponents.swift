import AteKit
import SwiftUI

/// The small, shared pieces both detail screens are built from. Deliberately plain: the designed
/// dish card arrives with the Log build (brief D), and these views are sized to be swapped for it
/// without touching either screen's structure.

// MARK: - Rating

/// Half-star row for an *aggregate* (4.3 → four filled and a half) or a single review's score.
/// Hidden from VoiceOver — the accompanying text carries the value, so the rating is announced once.
struct StarRowView: View {
    let score: Double?
    var size: CGFloat = Theme.Size.star

    var body: some View {
        let stars = ScoreFormat.stars(for: score)
        HStack(spacing: Theme.Spacing.hairline) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(at: index, stars: stars))
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(score == nil ? Theme.Color.textTertiary : Theme.Color.accent)
        .accessibilityHidden(true)
    }

    private func symbol(at index: Int, stars: (full: Int, half: Bool)) -> String {
        if index < stars.full { return "star.fill" }
        if index == stars.full, stars.half { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// The aggregate headline: stars, `4.3/5` (or `–/5` when unrated), and the review count.
///
/// The unrated case is a *product state*, not an error or a zero — so it gets its own line of copy
/// rather than a greyed-out number (data-model §1.3).
struct AggregateScoreView: View {
    let score: Double?
    let reviewCount: Int
    /// Copy for the unrated state — a dish invites a first review, a restaurant reads differently.
    var unratedCaption: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
                Text(ScoreFormat.outOfFive(score))
                    .font(Theme.Text.metric)
                    .foregroundStyle(score == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                StarRowView(score: score)
            }
            Text(score == nil ? unratedCaption : ScoreFormat.reviewCount(reviewCount))
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            score == nil
                ? unratedCaption
                : "\(ScoreFormat.outOfFive(score)), \(ScoreFormat.reviewCount(reviewCount))"
        )
    }
}

// MARK: - Media

/// A review photo at the one ratio the app uses. Reserves its space before the image lands so the
/// list doesn't jump under a scrolling thumb.
struct DetailPhotoView: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Theme.Color.placeholder
        }
        .aspectRatio(Theme.Ratio.photo, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityHidden(true)
    }
}

/// Square thumbnail for a dish row. Falls back to a neutral surface, never a broken-image glyph.
struct DishThumbnailView: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Theme.Color.placeholder
        }
        .frame(width: Theme.Size.thumbnail, height: Theme.Size.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// One review, neutrally presented: who, when, what they scored it, the note, the photo.
///
/// No like / comment / save affordances — the columns exist server-side but V1 renders none of them
/// (PRODUCT.md). This is the view the designed DishCard replaces later.
struct ReviewRowView: View {
    let review: Review
    let author: User?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text(author?.handle ?? "Someone")
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer(minLength: Theme.Spacing.snug)
                Text(review.createdAt, format: .relative(presentation: .named))
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            HStack(spacing: Theme.Spacing.snug) {
                StarRowView(score: review.score.value)
                Text(ScoreFormat.outOfFive(review.score.value))
                    .font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(ScoreFormat.outOfFive(review.score.value))")

            if let note = review.note, !note.isEmpty {
                Text(note)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textPrimary)
            }

            if let photoURL = review.photoURL {
                DetailPhotoView(url: photoURL)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }
}

/// One dish in a restaurant's list. The score is the dish's own average — `–/5` when nobody has
/// ordered it yet, which is a feature of the list, not a gap in it.
struct DishRowView: View {
    let dish: RankedDish

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            DishThumbnailView(url: dish.coverURL)
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(dish.name)
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                HStack(spacing: Theme.Spacing.snug) {
                    StarRowView(score: dish.score)
                    Text(ScoreFormat.outOfFive(dish.score))
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text(ScoreFormat.reviewCount(dish.reviewCount))
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Screen states

/// The first-load spinner, centred in a list row.
struct DetailLoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.loose)
            .listRowBackground(Theme.Color.background)
    }
}

/// A failed first load. Stock `ContentUnavailableView` so it looks like every other Apple app.
struct DetailErrorView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await retry() } }
                .buttonStyle(.bordered)
        }
        .listRowBackground(Theme.Color.background)
    }
}

/// The "log this" call to action. One button, one place, so both screens read identically (rule 2:
/// the same action works the same everywhere it appears).
struct LogDishButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.Color.background)
    }
}
