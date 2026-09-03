import AteKit
import SwiftUI

// The small, shared pieces both detail screens are built from. Deliberately plain: the designed
// dish card arrives with the Log build (brief D), and these views are sized to be swapped for it
// without touching either screen's structure.

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
                // Fixed cell so the narrower half-star glyph never re-spaces the row.
                Image(systemName: symbol(at: index, stars: stars))
                    .font(.system(size: size))
                    .frame(width: StarRow.cellWidth(for: size), height: size)
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

/// **The aggregate hero** (design-language §2, §8.6): the number, its stars, and how many people
/// said so — sitting on the PLANE above the first Group, not inside a well of its own.
///
/// That placement is the screen's identity. A dish page and a restaurant page open with the same
/// shape ("a public thing with an aggregate") and then diverge; wrapping the hero in a card would
/// make it the third grey block on a screen of grey blocks, which is exactly the diagnosis this
/// design pass started from.
///
/// The unrated case is a *product state*, not an error or a zero — so it gets its own line of copy
/// rather than a greyed-out number (data-model §1.3).
struct AggregateHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let score: Double?
    let reviewCount: Int
    /// Copy for the unrated state — a dish invites a first review, a restaurant reads differently.
    var unratedCaption: String
    /// The line under the title on screens that carry one in the content (the restaurant's suburb).
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
                Text(ScoreFormat.outOfFive(score))
                    .font(Theme.Text.heroMetric)
                    .foregroundStyle(score == nil ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    // §6 moment #4: a score that changes in place rolls rather than swaps. This is
                    // the one that fires after your own review lands and the aggregate moves.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: score)
                StarRowView(score: score)
            }
            Text(score == nil ? unratedCaption : ScoreFormat.reviewCount(reviewCount))
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.regular)
        .listRowSeparator(.hidden)
        // NO fill and NO radius — that is what "on the plane" means (§1.1). The hero is the first
        // thing on the page and must not read as the first of several grey blocks; the Group below
        // it is the only container on the screen above the fold.
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let aggregate = score == nil
            ? unratedCaption
            : "\(ScoreFormat.outOfFive(score)), \(ScoreFormat.reviewCount(reviewCount))"
        guard let subtitle, !subtitle.isEmpty else { return aggregate }
        return "\(subtitle), \(aggregate)"
    }
}

// MARK: - Media

/// A review photo at the one ratio the app uses. Reserves its space before the image lands so the
/// list doesn't jump under a scrolling thumb.
///
/// The `Color.clear` well is what sizes the row (the same fix the feed row carries): an `AsyncImage`
/// left to size itself pushes the photo's *intrinsic* width into the layout, which widens the row
/// and shoves the review's name and note off the left edge — seen on the simulator, not theorised.
struct DetailPhotoView: View {
    let url: URL?

    var body: some View {
        Color.clear
            .aspectRatio(Theme.Ratio.photo, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.Color.placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// **One person's review, in a stream of people** (design-language §2, §8.5).
///
/// The dish page's body is PERSON-LED: an avatar in a 44pt left gutter, then a text column of
/// handle + time, score, note, photo. No dish name and no place — you are already on the dish's
/// page, and repeating them per row is what made five reviews read as "one review with comments".
/// Five avatar gutters with full-bleed hairlines can only read as five people.
///
/// No like / comment / save affordances — the columns exist server-side but V1 renders none of them
/// (PRODUCT.md).
struct ReviewStreamRow: View {
    let review: Review
    let author: User?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.regular) {
            AvatarView(url: author?.avatarURL, size: Theme.Size.avatarGutter)

            VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
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
                    Text(ScoreFormat.halfStep(review.score.value))
                        .font(Theme.Text.rowScore)
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
        }
    }
}

/// One dish in a restaurant's list — a **destination**, not a peer. Always-filled 56pt tile, name,
/// score, and the system's chevron from the `NavigationLink` that wraps it.
struct DishRowView: View {
    let dish: RankedDish

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            DishTile(
                dish: DishTileSubject(id: dish.id, name: dish.name, photoURL: dish.coverURL),
                size: Theme.Size.thumbnail
            )
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

// `DetailLoadingView` is gone. §5: a spinner is for *appended* work — load-more, posting, rendering
// the receipt. A first load gets the page's own components, redacted, so nothing reflows when the
// data lands. See `DetailSkeletons.swift`.

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

// `LogDishButton` is gone: §2 gives each detail screen exactly ONE actions Group, and "log this" is
// a row in it beside the other ways out — not a filled bar competing with the aggregate for the top
// of the screen. The action, its copy and its `log_cta_tapped` event are unchanged.

/// Applies a navigation subtitle only when there is one. An empty subtitle is still a subtitle, and
/// it leaves a gap under the title while a detail screen is still loading its name.
struct DetailSubtitle: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}
