import AteKit
import SwiftUI

/// **`Saved`** — the shelf beside your journal: the dishes you meant to eat, grouped by where they
/// are served.
///
/// Dish-first by construction. A save is one dish (PRODUCT.md decision 7), so a row *is* a dish: a
/// thumbnail, its name, whose entry it came from, what everyone has scored it, and the bookmark that
/// takes it back off the shelf. The place is a heading over its dishes, not a row of its own.
struct SavedScreen: View {
    let store: SavedDishesStore
    /// The place head, and a row: both go somewhere that does not exist yet (slice 2).
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (SavedDish) -> Void = { _ in }
    var onUnsave: (SavedDish) -> Void = { _ in }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                SavedSkeleton()
            case .empty:
                AteEmptyState(title: "Nothing saved\nyet.")
            case .signedOut:
                AteEmptyState(title: "Nobody's\nsigned in.")
            case .failed(let message):
                AteEmptyState(title: message)
            case .ready:
                groups
            }
        }
        .task { await store.loadIfNeeded() }
    }

    private var groups: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.groups) { group in
                placeHead(group)
                ForEach(group.dishes) { dish in
                    SavedDishRow(
                        dish: dish,
                        onTap: { onDish(dish) },
                        onUnsave: { onUnsave(dish) }
                    )
                    .task { await store.loadMoreIfNeeded(after: dish) }
                }
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
    }

    /// `padding:18px 0 10px` — the place, its suburb, and the chevron onward.
    private func placeHead(_ group: SavedDishGroup) -> some View {
        Button {
            onPlace(group.restaurantID)
        } label: {
            HStack(spacing: 6) {
                Text(group.restaurantName).ateText(.slipPlace)
                if let city = group.city {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                }
                Spacer(minLength: 0)
                AteIcon.chevron.view(size: 15)
            }
            .padding(.top, 18)
            .padding(.bottom, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("saved.place")
    }
}

/// One saved dish: 56pt thumbnail, the dish, whose entry it came from, the score token, the filled
/// bookmark that unsaves it.
struct SavedDishRow: View {
    let dish: SavedDish
    var onTap: () -> Void
    var onUnsave: () -> Void

    /// The artboard's own row: `min-height:76px; gap:12px`, ruled at the top.
    private static let height: CGFloat = 76
    private static let thumbnail: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            AteHairline()
            HStack(spacing: AteMetrics.regular) {
                Button(action: onTap) {
                    HStack(spacing: AteMetrics.regular) {
                        AteThumbnail(
                            photo: AtePhoto(url: dish.dishCoverURL.flatMap(URL.init(string:))),
                            side: Self.thumbnail
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dish.dishName)
                                .ateText(.rowTitle)
                                .foregroundStyle(AtePalette.automatic.fg)
                            if let handle = dish.sourceUsername {
                                Text(verbatim: "from @\(handle)")
                                    .ateText(.meta)
                                    .foregroundStyle(AtePalette.automatic.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        score
                    }
                    .frame(minHeight: Self.height)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                bookmark
            }
        }
        .accessibilityIdentifier("saved.dish")
    }

    /// The dish's community aggregate, printed as sent (`Saved.dc.html` prints 4.2, 4.4, 4.7 — an
    /// average is a price, and only a star glyph rounds to the half). Nobody's score yet is the
    /// full-strength empty star (design rule 7), exactly as Search's own rows draw it — this row is
    /// Search's Saved row too.
    @ViewBuilder
    private var score: some View {
        if let value = dish.dishScore {
            ScoreToken(average: value, prose: 16)
        } else {
            UnscoredMark(side: 18)
                .foregroundStyle(AtePalette.automatic.fg)
        }
    }

    private var bookmark: some View {
        Button(action: onUnsave) {
            AteIcon.saved.view(size: 20)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtePalette.automatic.fg)
        // `margin-right:-2px` — the mark sits on the gutter, like every other trailing glyph.
        .padding(.trailing, -12)
        .accessibilityLabel("Saved \(dish.dishName)")
        .accessibilityAddTraits([.isButton, .isSelected])
        .accessibilityIdentifier("saved.unsave")
    }
}

/// The shelf's first load, drawn as the rows it is waiting for.
private struct SavedSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                if index.isMultiple(of: 2) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AtePalette.automatic.hairline)
                        .frame(width: 140, height: 22)
                        .padding(.top, 18)
                        .padding(.bottom, 10)
                }
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        RoundedRectangle(cornerRadius: AteMetrics.receiptTop, style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 56, height: 56)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 160, height: 14)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 76)
                }
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityHidden(true)
    }
}
