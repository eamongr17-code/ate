import AteKit
import SwiftUI

/// **Below a dish's reviews** (round 7, `DishExplore.dc.html`): "More to explore" — the dish's tags
/// as chips, each a door to its own page of dishes — and "More like this", a carousel of the dishes
/// most like it, each a door to that dish.
///
/// The markup's column: `gap:12px`, each heading `padding-top:8px` — so 20 from the last review to
/// "More to explore", 12 to its chips, 20 to "More like this", 12 to the cards. The chips and the
/// headings sit on the page's gutter; the carousel runs off the right edge (`margin-right:-16px`).
///
/// Read after the page's own read, both at once, and drawn once: until then the headings stand over
/// still shapes at the sections' final size, so nothing above or below them moves when they fill in.
/// A section with nothing in it is not on the page at all.
struct DishExploreSections: View {
    let store: DishExploreStore
    let onTag: (DishTag) -> Void
    /// The card, and its 1-based place along the carousel.
    let onDish: (SimilarDish, Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            if store.showsTags {
                heading("More to explore")
                chips
            }
            if store.showsSimilar {
                heading("More like this")
                carousel
            }
        }
        .padding(.top, Self.gap)
        .ateAnimation(AteMotion.fillIn, value: store.isSettled)
    }

    /// `gap:12px` down the page's column.
    static let gap: CGFloat = 12
    /// A heading's `padding-top:8px`.
    private static let headingTop: CGFloat = 8
    /// `gap:8px`, both ways, between the chips.
    private static let chipGap: CGFloat = 8
    /// `height:34px; padding:0 14px`.
    static let chipHeight: CGFloat = 34
    private static let chipPadding: CGFloat = 14

    private func heading(_ title: String) -> some View {
        Text(title)
            .ateTextLine(.exploreHeading)
            .foregroundStyle(AtePalette.automatic.fg)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, Self.headingTop)
            .padding(.horizontal, AteMetrics.listGutter)
    }

    // MARK: - More to explore

    @ViewBuilder
    private var chips: some View {
        Group {
            if store.isSettled {
                AteFlow(spacing: Self.chipGap) {
                    ForEach(store.tags) { tag in
                        AteChip(
                            title: tag.title,
                            height: Self.chipHeight,
                            sidePadding: Self.chipPadding,
                            textStyle: .exploreChip
                        ) {
                            onTag(tag)
                        }
                        .accessibilityIdentifier("dish.explore.tag")
                    }
                }
                .transition(.opacity)
            } else {
                // One line of chips, the shape they arrive in.
                HStack(spacing: Self.chipGap) {
                    ForEach([74, 62, 96, 58], id: \.self) { width in
                        Capsule()
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: CGFloat(width), height: Self.chipHeight)
                    }
                }
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AteMetrics.listGutter)
    }

    // MARK: - More like this

    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SimilarDishCard.gap) {
                if store.isSettled {
                    let letters = DishLetter.neighbourly(store.similar.map { ($0.dishID, $0.name) })
                    ForEach(Array(store.similar.enumerated()), id: \.element.id) { index, dish in
                        SimilarDishCard(dish: dish, letter: letters[index]) {
                            onDish(dish, index + 1)
                        }
                        .transition(.opacity)
                    }
                } else {
                    ForEach(0..<3, id: \.self) { _ in
                        SimilarDishCardSkeleton()
                            .transition(.opacity)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, AteMetrics.listGutter, for: .scrollContent)
        .scrollDisabled(store.isSettled == false)
        .frame(height: SimilarDishCard.height(dynamicTypeSize))
        .accessibilityIdentifier("dish.explore.similar")
    }
}

/// **One dish like this one** — `width:150px; gap:6px`: a 150 photo at radius 26, the dish (15/700,
/// two lines at most), then its place and its score (13, muted). Straight, never tilted: it is a row
/// of thumbnails, not a cluster (design rule 6). A dish nobody has scored prints its place alone —
/// no star, no zero (rule 7).
struct SimilarDishCard: View {
    let dish: SimilarDish
    var letter: DishLetter?
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let width: CGFloat = 150
    /// `border-radius:26px` — the artboard's own, not the 28% squircle.
    static let radius: CGFloat = 26
    /// `gap:12px` between the cards; `gap:6px` down one.
    static let gap: CGFloat = 12
    static let stack: CGFloat = 6
    private static let star: CGFloat = 11

    /// The carousel's one height: the photo, a two-line name and the place line — so a card with a
    /// short name never makes the row shorter than one with a long one, and the page below the
    /// carousel never moves as it fills in.
    static func height(_ size: DynamicTypeSize) -> CGFloat {
        width + stack + AteTextStyle.exploreCardName.lineBox(size) * 2 + stack
            + max(AteTextStyle.exploreCardMeta.lineBox(size), star)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Self.stack) {
                AteThumbnail(
                    photo: .dish(
                        letter ?? DishLetter(dishID: dish.dishID, name: dish.name),
                        cover: dish.coverURLString
                    ),
                    side: Self.width,
                    radius: Self.radius
                )
                Text(dish.name)
                    .ateTextExact(.exploreCardName)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(AtePalette.automatic.fg)
                meta
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("dish.explore.card")
    }

    /// The place left and `★ 4.4` right, across the card's width — two values, no dot between them
    /// (design rule 2; the artboard's " · " is overruled). `gap:4px` from the star to its number. The
    /// place gives way first; the score never does.
    private var meta: some View {
        HStack(spacing: AteMetrics.snug) {
            Text(dish.restaurantName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let score = dish.score {
                HStack(spacing: AteMetrics.tight) {
                    AteIcon.starFilled.view(size: Self.star)
                    Text(ScoreFormat.average(score))
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
        .ateTextExact(.exploreCardMeta)
        .foregroundStyle(AtePalette.automatic.muted)
        .frame(height: max(AteTextStyle.exploreCardMeta.lineBox(dynamicTypeSize), Self.star))
    }

    private var accessibilityText: String {
        [dish.name, dish.restaurantName, dish.score.map { "Rated \(ScoreFormat.average($0))" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// A card before the read has answered: the photo and two lines, still.
private struct SimilarDishCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SimilarDishCard.stack) {
            RoundedRectangle(cornerRadius: SimilarDishCard.radius, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: SimilarDishCard.width, height: SimilarDishCard.width)
            AteSkeletonBar(width: 118, height: 14, palette: .automatic)
            AteSkeletonBar(width: 84, height: 11, palette: .automatic)
        }
        .frame(width: SimilarDishCard.width, alignment: .leading)
        .accessibilityHidden(true)
    }
}
