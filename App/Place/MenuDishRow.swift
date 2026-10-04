import AteKit
import SwiftUI

/// One line of **what to order**: the rank, a straight 48pt thumbnail (design rule 6 — nothing in a
/// list tilts), the dish with its dietary chips, how many people have scored it, and the score
/// printed like a price.
///
/// The dashed rule is **between** dishes, never above the first (round 4). A cover photo is its own
/// control and opens the photo viewer; a letter tile is part of the row and opens the dish.
struct MenuDishRow: View {
    let dish: MenuDish
    /// 1-based, and a fact about the *list* rather than about the dish — so it is handed in.
    let rank: Int
    /// The tile the menu chose for this row (``DishLetter/neighbourly(_:)``).
    var letter: DishLetter?
    var onPhoto: () -> Void = {}
    let action: () -> Void

    /// `min-height:66px; gap:12px`, ruled at the top with the receipt's own dashed line.
    private static let height: CGFloat = 66
    private static let thumbnail: CGFloat = 48
    private static let thumbnailRadius: CGFloat = 14
    /// `.lab` at `width:18px` — the rank column, so every dish name starts on the same vertical.
    private static let rankWidth: CGFloat = 18

    /// The receipt it is printed on — light type on the plum slip in dark, ink on white in light.
    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        VStack(spacing: 0) {
            if rank > 1 { AteDashedRule() }
            if dish.coverURL != nil {
                // Three siblings, because a tap inside a button's label belongs to that button:
                // the rank and the words open the dish, the photo opens itself.
                HStack(spacing: AteMetrics.regular) {
                    Button(action: action) { rankLabel.frame(maxHeight: .infinity).contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    Button {
                        onPhoto()
                        showPhotos([photo], at: 0)
                    } label: {
                        thumbnail.frame(maxHeight: .infinity).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo of \(dish.name)")
                    .accessibilityIdentifier("place.dish.photo")
                    Button(action: action) { words.frame(maxHeight: .infinity).contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("place.dish")
                }
                .frame(minHeight: Self.height)
            } else {
                Button(action: action) {
                    HStack(spacing: AteMetrics.regular) {
                        rankLabel
                        thumbnail
                        words
                    }
                    .frame(minHeight: Self.height)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("place.dish")
            }
        }
    }

    private var photo: AtePhoto {
        AtePhoto(id: dish.dishID, url: dish.coverURL, dish: letter ?? DishLetter(dishID: dish.dishID, name: dish.name))
    }

    private var rankLabel: some View {
        Text(String(format: "%02d", rank))
            .ateText(.receiptLabel)
            // 18 wide at the design's size; the two digits never break across lines.
            .fixedSize()
            .frame(minWidth: Self.rankWidth, alignment: .leading)
    }

    /// `width:48px; border-radius:14px` — its cover, or its letter tile (`NoPhotoA`).
    private var thumbnail: some View {
        AteThumbnail(photo: photo, side: Self.thumbnail, radius: Self.thumbnailRadius)
    }

    private var words: some View {
        // At the accessibility sizes the score moves under the dish, so the name has the row.
        let stacks = dynamicTypeSize.isAccessibilitySize
        return HStack(spacing: AteMetrics.regular) {
            VStack(alignment: .leading, spacing: 1) {
                // The dish IS the item; an elided one is a dish nobody can recognise.
                DishNameText(name: dish.name, tags: dish.tags, style: .menuDish)
                    .fixedSize(horizontal: false, vertical: true)
                if dish.peopleCount > 0 {
                    HStack(spacing: AteMetrics.tight) {
                        AteIcon.feed.view(size: 13)
                        Text(dish.peopleCount.formatted()).ateText(.meta)
                    }
                    .foregroundStyle(palette.muted)
                }
                if stacks { score }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if stacks == false { score }
        }
    }

    /// Design rule 7: an unrated dish leaves the score slot empty — never a zero, never a mark.
    @ViewBuilder
    private var score: some View {
        if let value = dish.score {
            Text(ScoreFormat.average(value))
                .ateText(.menuScore)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel("Rated \(ScoreFormat.average(value))")
        }
    }
}
