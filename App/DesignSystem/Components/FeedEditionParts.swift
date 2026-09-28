import AteKit
import SwiftUI

// **The Feed's edition, piece by piece** (round 8, `Main.dc.html`): a section's heading, the dish card
// and the carousel it runs in, a New to the record row, the cravings row and the quiet end. Every dish
// here is saveable in place with the one ``AteSaveButton``; a dish with no photo is its letter tile.

enum FeedEditionMetrics {
    /// Headings and rows sit 20 in; the paper and the rows that are cards sit 16 in (`margin:0 16px`).
    static let gutter: CGFloat = 20
    static let cardMargin: CGFloat = 16
    /// A heading: `padding:34px 20px 14px` (The Top Ate's 30); `gap:10px` to See all.
    static let headingTop: CGFloat = 34
    static let topAteHeadingTop: CGFloat = 30
    static let headingBottom: CGFloat = 14
    /// The latest receipts: `gap:14px`.
    static let receiptGap: CGFloat = 14
    /// "You're caught up": `padding:40px 20px 0; gap:14px`, then 34 under it.
    static let caughtUpTop: CGFloat = 40
    static let caughtUpBottom: CGFloat = 34
}

// MARK: - A section's heading

/// `sec()` — the section's name, 28/800, and See all at its right on a shelf. No eyebrow above it.
struct FeedSectionHeading: View {
    let title: String
    var top: CGFloat = FeedEditionMetrics.headingTop
    var onSeeAll: (() -> Void)?
    var identifier = "feed.section"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(title)
                .ateTextExact(.feedSection)
                .offset(y: -AteFont.exactBaselineDrop(for: .feedSection, dynamicTypeSize: dynamicTypeSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(palette.fg)
                .accessibilityAddTraits(.isHeader)
            if let onSeeAll {
                let hit = AteHitOutset(height: 18)
                Button(action: onSeeAll) {
                    HStack(spacing: 2) {
                        Text("See all").ateText(.feedControl)
                        AteIcon.chevron.view(size: 16, lineWidth: 2 * AteIconShape.opticalScale)
                    }
                    .foregroundStyle(palette.muted)
                    .ateHitArea(hit)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(hit)
                // `padding-bottom:3px`.
                .padding(.bottom, 3)
                .accessibilityIdentifier("\(identifier).seeAll")
            }
        }
        .padding(.top, top)
        .padding(.horizontal, FeedEditionMetrics.gutter)
        .padding(.bottom, FeedEditionMetrics.headingBottom)
    }
}

// MARK: - The card and its carousel

/// `card()` — a dish as a card: a 168×210 photo at radius 30 (or its letter tile), its score as the
/// butter token on the photo's corner, then the dish, its place and its bookmark. Straight, never
/// tilted — it is a row of thumbnails, not a cluster (design rule 6).
struct FeedDishCard: View {
    let dish: FeedDish
    let letter: DishLetter
    let onOpen: () -> Void
    let onSave: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette

    static let width: CGFloat = 168
    static let photoHeight: CGFloat = 210
    static let radius: CGFloat = 30
    /// `gap:12px` between cards; `gap:8px` under the photo; `gap:2px` between the dish and its place.
    static let gap: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                AtePhotoContent(photo: .dish(letter, cover: dish.coverURLString), size: .forSide(Self.photoHeight))
                    .frame(width: Self.width, height: Self.photoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let score = dish.score {
                            FeedScoreToken(score: score).padding(12)
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 2) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dish.name)
                            .ateTextExact(.feedCardDish)
                            .offset(y: -AteFont.exactBaselineDrop(for: .feedCardDish, dynamicTypeSize: dynamicTypeSize))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(palette.fg)
                        Text(dish.restaurantName)
                            .ateText(.feedPlace)
                            .lineLimit(1)
                            .foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("feed.card")
                // `margin:-10px -10px 0 0`.
                AteSaveButton(dishName: dish.name, isSaved: dish.isSaved, identifier: "feed.save", action: onSave)
                    .padding(.top, -10)
                    .padding(.trailing, -10)
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private var accessibilityText: String {
        [dish.name, dish.restaurantName, dish.score.map { "Rated \(ScoreFormat.average($0))" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// The score token on a card's photo: butter, a filled star and the number, mono 13
/// (`padding:2px 9px; gap:3px`).
struct FeedScoreToken: View {
    let score: Double

    var body: some View {
        HStack(spacing: 3) {
            AteIcon.starFilled.view(size: 10)
            Text(ScoreFormat.average(score))
                .ateText(.feedCardScore)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(AteColor.scoreFill, in: .capsule)
        .foregroundStyle(AteColor.scoreInk)
        .accessibilityHidden(true)
    }
}

/// `shelf()` — the cards in a row that runs off the right edge, from the 20 gutter.
struct FeedDishCarousel: View {
    let dishes: [FeedDish]
    var identifier = "feed.carousel"
    let onDish: (FeedDish) -> Void
    let onSave: (FeedDish) -> Void

    var body: some View {
        let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: FeedDishCard.gap) {
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    FeedDishCard(dish: dish, letter: letters[index], onOpen: { onDish(dish) }, onSave: {
                        onSave(dish)
                    })
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, FeedEditionMetrics.gutter, for: .scrollContent)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - New to the record

/// `newrow()` — the dish's 56 thumbnail at radius 18, the dish and its place, the badge (`★6` brick,
/// `★5` butter, `New` field) and the bookmark; a hairline in the field colour under every row but the
/// last. The place prints alone: two values are never joined with " · " (design rule 2).
struct NewDishRow: View {
    let row: NewDish
    let letter: DishLetter
    let isLast: Bool
    let onOpen: () -> Void
    let onSave: () -> Void

    @Environment(\.atePalette) private var palette

    static let thumbnail: CGFloat = 56
    static let radius: CGFloat = 18

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    AteThumbnail(photo: .dish(letter, cover: row.dish.coverURLString), side: Self.thumbnail,
                                 radius: Self.radius)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.dish.name)
                            .ateText(.feedNewDish)
                            .lineLimit(2)
                            .foregroundStyle(palette.fg)
                        Text(row.dish.restaurantName)
                            .ateText(.feedPlace)
                            .lineLimit(1)
                            .foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    badge
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed.new.dish")
            // `margin-right:-10px`.
            AteSaveButton(dishName: row.dish.name, isSaved: row.dish.isSaved, identifier: "feed.save", action: onSave)
                .padding(.trailing, -10)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if isLast == false {
                Rectangle().fill(palette.field).frame(height: 1)
            }
        }
    }

    /// `padding:3px 10px; border-radius:999px`.
    private var badge: some View {
        Text(row.badge)
            .ateText(.feedBadge)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(badgeFill, in: .capsule)
            .foregroundStyle(badgeInk)
            .fixedSize()
    }

    private var badgeFill: Color {
        switch row.kind {
        case .six: AteFeedColor.six
        case .five: AteFeedColor.five
        case .new: palette.field
        }
    }

    private var badgeInk: Color {
        switch row.kind {
        case .six: AteFeedColor.sixInk
        case .five: AteFeedColor.fiveInk
        case .new: palette.fg
        }
    }
}

// MARK: - The cravings row and the end

/// "Choose your cravings" — `margin:26px 16px 0; height:64px; border-radius:22px`, the chip colour, a
/// muted chevron. It opens the picker.
struct ChooseCravingsRow: View {
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    static let top: CGFloat = 26
    static let height: CGFloat = 64
    static let radius: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("Choose your cravings")
                    .ateText(.feedRow)
                    .foregroundStyle(palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AteIcon.chevron.view(size: 18, lineWidth: 2 * AteIconShape.opticalScale)
                    .foregroundStyle(palette.muted)
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .frame(minHeight: Self.height)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, Self.top)
        .padding(.horizontal, FeedEditionMetrics.cardMargin)
        .accessibilityIdentifier("feed.cravings.choose")
    }
}

/// "You're caught up" — the edition's quiet end: a rule either side of one muted line. No button.
struct FeedCaughtUp: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Rectangle().fill(AteFeedColor.rule).frame(height: 1)
            Text("You're caught up")
                .ateText(.feedControl)
                .foregroundStyle(palette.muted)
                .fixedSize()
            Rectangle().fill(AteFeedColor.rule).frame(height: 1)
        }
        .padding(.top, FeedEditionMetrics.caughtUpTop)
        .padding(.horizontal, FeedEditionMetrics.gutter)
        .padding(.bottom, FeedEditionMetrics.caughtUpBottom)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.caughtUp")
    }
}
