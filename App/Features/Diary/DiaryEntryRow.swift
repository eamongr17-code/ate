import AteKit
import SwiftUI

/// One dish you rated, as a line in your record (§3.3).
///
/// **Not a `DishCard`.** The card is the right rendering of *a review you are reading*; the diary is
/// a list of things you ate, and forty cards is a scroll rather than a record. The full card moves to
/// the entry view, one tap away, where there is exactly one of it.
///
/// The minimum row — a score and a name, no note, no photo — is the most common one there will ever
/// be, so it is the one this is laid out for: no reserved photo well, no empty note line, nothing
/// that reads as missing.
struct DiaryEntryRow: View {
    let entry: FeedEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            // §10.5: absent, not a grey box. A placeholder for a photo that was never taken says
            // something failed.
            if let url = entry.review.photoURL {
                DiaryThumbnail(url: url)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                // §10.6: the name stored on *your* review. A later merge rewrites where the dish
                // page lives, never what your record says you ate.
                Text(entry.dish.name)
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(2)

                if let note = entry.review.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !note.isEmpty {
                    Text(note)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.snug)

            Text(ScoreFormat.halfStep(entry.review.score.value))
                .font(Theme.Text.rowScore)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The row's 56pt square. Its own type rather than `DishThumbnailView` (which belongs to the detail
/// screens' file, Lane B's surface) — same tokens, same shape, one import boundary fewer.
private struct DiaryThumbnail: View {
    let url: URL

    var body: some View {
        // Cropped square from a 4:3 original, per §3.3 — `scaledToFill` inside a fixed frame is that
        // crop, and clipping is what stops the overflow painting over the name.
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
