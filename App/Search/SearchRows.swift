import AteKit
import SwiftUI

/// **The Search tab's rows.** Design rule 3's "everything else": no container, a hairline above each
/// one, the score printed at the right.
///
/// Three shapes, because the artboards draw two and the third has to be built from the same
/// vocabulary: a place (pin · name · suburb · score, 62 tall), a dish (56pt cover · name · place ·
/// score, 76 tall) and a person — not drawn — which is the place row's geometry with the byline
/// avatar the feed already uses in the leading column.
///
/// The fourth, a saved dish, is not here at all: it is ``SavedDishRow``, unchanged, because a saved
/// dish found through Search and a saved dish on the shelf are the same row carrying the same
/// bookmark (AGENTS.md rule 2).

/// One place: `min-height:62px; gap:12px`, ruled at the top (`Search.dc.html`).
///
/// The words are the card's place line (`.placeline`: the place in the control weight, then its
/// suburb in muted meta, `gap:5px`) at the row's own 17pt — **not** the artboard's two-line
/// name-over-cuisine, which the lead redirected on 2026-09-25 so a place reads the same on every
/// screen. The place truncates first; the suburb never wraps and never truncates.
struct PlaceResultRow: View {
    let place: PlaceResult
    let action: () -> Void

    static let height: CGFloat = 62
    /// `.placeline`'s `gap:5px`, between the place and its suburb.
    private static let suburbGap: CGFloat = 5

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the suburb and the score left the name no room at all ("…"):
        // the three stack instead, the name first.
        let stacks = dynamicTypeSize.isAccessibilitySize
        let words = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Self.suburbGap))
        return Button(action: action) {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteIcon.place.view(size: 20)
                    words {
                        Text(place.name)
                            .ateText(.rowTitle)
                            .foregroundStyle(AtePalette.automatic.fg)
                            .lineLimit(stacks ? 3 : 1)
                            .truncationMode(.tail)
                        if let suburb = place.locality {
                            Text(suburb)
                                .ateText(.meta)
                                .foregroundStyle(AtePalette.automatic.muted)
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        if stacks { SearchScoreMark(score: place.score) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if stacks == false { SearchScoreMark(score: place.score) }
                }
                .frame(minHeight: Self.height)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtePalette.automatic.fg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.place")
    }
}

/// One dish: `min-height:76px; gap:12px`, a straight 56pt cover (design rule 6 — nothing in a list
/// tilts), the place under the name (`SearchResults.dc.html`).
struct DishResultRow: View {
    let dish: DishResult
    let action: () -> Void

    static let height: CGFloat = 76
    private static let thumbnail: CGFloat = 56

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the score moves under the place, so the name has the row.
        let stacks = dynamicTypeSize.isAccessibilitySize
        return Button(action: action) {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteThumbnail(
                        photo: AtePhoto(id: dish.dishID, url: dish.coverURL,
                                        dish: DishLetter(dishID: dish.dishID, name: dish.name)),
                        side: Self.thumbnail
                    )
                    VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                        Text(dish.name)
                            .ateText(.rowTitle)
                            .foregroundStyle(AtePalette.automatic.fg)
                            // The dish IS the item; an elided one is a dish nobody can recognise.
                            .fixedSize(horizontal: false, vertical: true)
                        Text(dish.restaurantName)
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.automatic.muted)
                        if stacks { SearchScoreMark(score: dish.score) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if stacks == false { SearchScoreMark(score: dish.score) }
                }
                .frame(minHeight: Self.height)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.dish")
    }
}

/// One person. Not drawn: the place row's geometry, with the feed's byline avatar where the pin
/// goes and the handle where the name goes. No score — a score is only ever somebody's, about a
/// dish (design rule 7) — and no follower count, because V1 has none.
struct PersonResultRow: View {
    let person: PersonResult
    let action: () -> Void

    private static let avatar: CGFloat = 36

    var body: some View {
        AteListRow(
            title: "@\(person.handle)",
            subtitle: person.name,
            minHeight: PlaceResultRow.height,
            leading: {
                AteAvatar(
                    userID: person.userID,
                    handle: person.handle,
                    side: Self.avatar,
                    textStyle: .avatarInitialMedium
                )
            },
            trailing: { EmptyView() },
            action: action
        )
        .accessibilityIdentifier("search.person")
    }
}

/// The score at the right of a row: the butter token when there is one — an aggregate, so printed
/// as sent (`4.3`, the artboards' own numbers) — and the full-strength empty star when there is not.
///
/// Rule 7: nobody's score is ever made up for a row, and "nobody has scored this" is an empty
/// score slot — no star, no mark, no zero.
struct SearchScoreMark: View {
    let score: Double?

    var body: some View {
        if let score {
            ScoreToken(average: score, prose: 16)
        }
    }
}

/// The rows before they arrive — the shape of the real ones, never a spinner.
struct SearchRowsSkeleton: View {
    var height: CGFloat = PlaceResultRow.height
    var hasThumbnail = false
    var count = 4

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        if hasThumbnail {
                            RoundedRectangle(cornerRadius: AteMetrics.receiptTop, style: .continuous)
                                .fill(AtePalette.automatic.hairline)
                                .frame(width: 56, height: 56)
                        }
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 150, height: 16)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: height)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Search rows") {
    ScrollView {
        VStack(spacing: 0) {
            PlaceResultRow(
                place: PlaceResult(restaurantID: UUID(), name: "Tipo 00", locality: "Melbourne", score: 4.3),
                action: {}
            )
            PlaceResultRow(
                place: PlaceResult(
                    restaurantID: UUID(), name: "A very long place name that has to give way",
                    locality: "North Melbourne", score: nil
                ),
                action: {}
            )
            DishResultRow(
                dish: DishResult(
                    dishID: UUID(), name: "Tagliatelle al ragù", restaurantID: UUID(),
                    restaurantName: "Tipo 00", score: 4.6
                ),
                action: {}
            )
            PersonResultRow(
                person: PersonResult(userID: UUID(), handle: "crumbsmelb", name: "Jess Okafor"),
                action: {}
            )
            SearchRowsSkeleton()
        }
        .padding(.horizontal, AteMetrics.gutter)
    }
    .ateGround()
}
#endif
