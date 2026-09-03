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

    /// The width the sitting-block hairline is inset by, so the rule starts where the text does and
    /// the run of dishes reads as one meal (design-language §1.2 — the app's one divider exception).
    /// Derived from the row's own geometry rather than typed as a number, so the two can't drift.
    static let textColumnInset = Theme.Spacing.gutter + Theme.Size.tileSmall + Theme.Spacing.gutter

    var body: some View {
        HStack(spacing: Theme.Spacing.gutter) {
            // §3: a dish is never a blank. The gutter tile is STRUCTURE — always filled, photo or
            // no photo — which is what stops a 40-row diary looking like a ragged list of things
            // that half-failed to load.
            DishTile(
                dish: DishTileSubject(
                    id: entry.dish.canonicalID,
                    name: entry.dish.name,
                    photoURL: entry.review.photoURL
                ),
                size: Theme.Size.tileSmall
            )

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

// `DiaryThumbnail` is gone: the row's square is `DishTile`, the one component every dish gutter in
// the app uses (§8.4). Three near-identical private thumbnails were three places for the fallback to
// be wrong.
