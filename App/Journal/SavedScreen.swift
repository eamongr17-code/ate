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
    /// Where this shelf begins on the screen, so its empty state is centred on the line every empty
    /// state shares (``AteEmptyPlacement``).
    var emptyTop: CGFloat = AteEmptyPlacement.bandTop
    /// The margin above the shelf. The shelf is rows of the journal's own lazy stack, not one view
    /// in it, so the margin goes on its first row rather than around the whole.
    var top: CGFloat = 0
    /// Takes the filters off — the filtered shelf's empty state (round 5).
    var onClear: () -> Void = {}
    /// The place head, and a row: both go somewhere that does not exist yet (slice 2).
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (SavedDish) -> Void = { _ in }
    var onUnsave: (SavedDish) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// **Rows, not a list of its own.** The shelf sits in the journal's scroll view, and a
    /// `LazyVStack` nested in that page's content is the shape that locked the Feed's main thread
    /// (`FeedScreen`) — so every place head and dish here is a row of the journal's own lazy stack.
    /// The journal also starts the shelf's load, when the shelf is chosen (`JournalScreen`).
    @ViewBuilder
    var body: some View {
        switch store.phase {
        case .loading:
            SavedSkeleton()
                .padding(.top, top)
        case .empty where store.filter.isEmpty == false:
            // The Journal's own words for a filter that finds nothing.
            LegacyEmptyState(title: "Nothing\nlike that.", actionTitle: "Clear", action: onClear)
                .ateEmptyPlacement(top: emptyTop)
                .padding(.top, top)
        case .empty:
            LegacyEmptyState(title: "Nothing saved\nyet.")
                .ateEmptyPlacement(top: emptyTop)
                .padding(.top, top)
        case .signedOut:
            LegacyEmptyState(title: "Nobody's\nsigned in.")
                .ateEmptyPlacement(top: emptyTop)
                .padding(.top, top)
        case .failed:
            AteUnreachableState { Task { await store.refresh() } }
                .ateEmptyPlacement(top: emptyTop)
                .padding(.top, top)
        case .ready:
            groups
        }
    }

    @ViewBuilder
    private var groups: some View {
        // The letter tiles are chosen for the shelf as it reads, top to bottom, so no two dishes
        // one above the other share an accent (round 4).
        let shelf = store.groups.flatMap(\.dishes)
        let letters = Dictionary(
            zip(shelf.map(\.id), DishLetter.neighbourly(shelf.map { ($0.dishID, $0.dishName) })),
            uniquingKeysWith: { first, _ in first }
        )
        let first = store.groups.first?.id
        if store.groups.isEmpty {
            // What the shelf's own (empty) stack used to hold: its margin, and nothing.
            Color.clear.frame(height: 0).padding(.top, top)
        }
        ForEach(store.groups) { group in
            placeHead(group)
                .padding(.top, group.id == first ? top : 0)
                // One card width everywhere (round 4): the shelf's rows sit on the segment's edge.
                .ateCardWidth()
            ForEach(group.dishes) { dish in
                SavedDishRow(
                    dish: dish,
                    letter: letters[dish.id],
                    onTap: { onDish(dish) },
                    onUnsave: { onUnsave(dish) }
                )
                .task { await store.loadMoreIfNeeded(after: dish) }
                .ateCardWidth()
            }
        }
    }

    /// `padding:18px 0 10px` — the place, its suburb, and the chevron onward.
    private func placeHead(_ group: SavedDishGroup) -> some View {
        Button {
            onPlace(group.restaurantID)
        } label: {
            HStack(spacing: 6) {
                // At the accessibility sizes the city goes under the place rather than squeezing
                // it into a word a line.
                let words = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(spacing: 6))
                words {
                    Text(group.restaurantName).ateText(.slipPlace)
                    if let city = group.city {
                        Text(city)
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.automatic.muted)
                    }
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
    /// The tile the shelf chose for this row, so it never matches the one above it.
    var letter: DishLetter?
    var onTap: () -> Void
    var onUnsave: () -> Void

    /// The artboard's own row: `min-height:76px; gap:12px`, ruled at the top.
    private static let height: CGFloat = 76
    private static let thumbnail: CGFloat = 56

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the score moves under the name, so the name has the row.
        let stacks = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: 0) {
            AteHairline()
            HStack(spacing: AteMetrics.regular) {
                Button(action: onTap) {
                    HStack(spacing: AteMetrics.regular) {
                        AteThumbnail(
                            photo: .dish(
                                letter ?? DishLetter(dishID: dish.dishID, name: dish.dishName),
                                cover: dish.dishCoverURL
                            ),
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
                            if stacks { score }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if stacks == false { score }
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
    /// average is a price, and only a star glyph rounds to the half). Nobody's score yet is an
    /// empty score slot (design rule 7), exactly as Search's own rows draw it — this row is
    /// Search's Saved row too.
    @ViewBuilder
    private var score: some View {
        if let value = dish.dishScore {
            ScoreToken(average: value, prose: 16)
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
        .ateCardWidth()
        .accessibilityHidden(true)
    }
}

/// **Undo**, after an unsave on the shelf — one ink pill, floating above the tab bar for four
/// seconds and then gone. The app's own pill (``AteButton``), hugging one word: no toast, no
/// sentence about what happened (design rule 1) — the row leaving is what happened, and this is
/// the way back.
struct SavedUndoPill: View {
    let store: SavedDishesStore
    let onUndo: () -> Void

    /// How long the way back stays open.
    private static let lifetime = Duration.seconds(4)
    /// A row's gap above whatever the tab leaves at the bottom — the tab bar's strip, full
    /// size or minimised.
    private static let bottom: CGFloat = AteMetrics.regular
    private static let height: CGFloat = AteMetrics.hit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let dish = store.undoable {
                AteButton(title: "Undo", height: Self.height, hugPadding: 22, action: onUndo)
                    .accessibilityLabel("Undo, put back \(dish.dishName)")
                    .accessibilityIdentifier("saved.undo")
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: dish.dishID) {
                        try? await Task.sleep(for: Self.lifetime)
                        guard Task.isCancelled == false else { return }
                        store.expireUndo(for: dish)
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.undoable?.dishID)
        .padding(.bottom, Self.bottom)
    }
}
