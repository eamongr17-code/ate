import AteKit
import SwiftUI

/// One review in the feed: dish over restaurant · suburb, the score, the note, the photo, and who
/// wrote it when.
///
/// **This is deliberately plain and deliberately one small view.** The designed `DishCard` arrives
/// with the Log flow and replaces this file's body wholesale; keeping the whole row here — with no
/// layout knowledge leaking into `FeedView` — makes that swap a one-line change at the call site.
/// Until then it is stock SwiftUI on Theme tokens, which is exactly what the neutral-chrome rule
/// asks for.
struct FeedRow: View {
    let entry: FeedEntry

    /// Long notes are clamped rather than truncated to a character count: three lines is the same
    /// budget at every Dynamic Type size, and the full note lives one tap away on dish detail.
    private static let noteLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            byline

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(entry.dish.name)
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(placeLine)
                    .font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            ScoreLabel(rating: entry.review.score)

            if let note = entry.review.note, !note.isEmpty {
                Text(note)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(Self.noteLineLimit)
                    .multilineTextAlignment(.leading)
            }

            if let photoURL = entry.review.photoURL {
                photo(photoURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.snug)
    }

    private var byline: some View {
        HStack(spacing: Theme.Spacing.snug) {
            avatar
            Text(entry.author?.handle ?? "Someone")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer(minLength: Theme.Spacing.snug)
            // The server stores an instant; the client formats it. "2d", not a stored string.
            Text(entry.review.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var avatar: some View {
        AsyncImage(url: entry.author?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Theme.Color.surface)
        }
        .frame(width: Theme.Size.avatarSmall, height: Theme.Size.avatarSmall)
        .clipShape(.circle)
    }

    /// A 4:3 well that takes the row's width, with the photo filling it.
    ///
    /// The well is what sizes the row — an `AsyncImage` sized by its *own* aspect ratio pushes its
    /// intrinsic width into the layout and shoves the rest of the row off screen (a real bug caught
    /// on the simulator, not a hypothetical). `Color.clear` sets the geometry; the image is an
    /// overlay clipped to it, so a portrait or panoramic photo can never change the row's shape.
    private func photo(_ url: URL) -> some View {
        Color.clear
            .aspectRatio(Theme.Media.photoAspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.Color.surface
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.card))
            .accessibilityLabel("Photo of \(entry.dish.name)")
    }

    /// "Tipo 00 · Melbourne", or just the restaurant when a manual row has no locality.
    private var placeLine: String {
        [entry.restaurant.name, entry.restaurant.locality]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

#Preview("Feed rows") {
    List {
        ForEach(FeedPlaceholder.entries(count: 3)) { entry in
            FeedRow(entry: entry)
        }
    }
    .listStyle(.plain)
}
