import AteKit
import SwiftUI

/// **`Restaurant`** — the place, and the one question it answers: what should I order here?
///
/// Three bands, in the order `Restaurant.dc.html` sets them down: the name at 44, a row of chips
/// carrying only the facts we actually hold, the ranked menu on receipt paper — and then the visits
/// written here as one stream with no heading (`RestaurantVisits`, 2026-09-26): yours first, each
/// with a "You" byline, then everyone else's.
///
/// Round 4: the page sits on the list gutter (12, the Journal's); it arrives whole — a still
/// skeleton of the full layout until the header, the menu and the visits are all in, then one fade;
/// the menu has no rule above its first dish; and a dish's photo on the menu opens the photo viewer
/// (its letter tile still opens the dish).
///
/// The average in the header is **read**, never computed: it is the mean of per-dish averages
/// (data-model §1.2), so averaging the menu below it would print a different, wrong number.
struct PlaceScreen: View {
    let store: PlacePageStore
    var onDish: (UUID) -> Void = { _ in }
    var onOpen: (EntryCard) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    var onSave: (EntryCard, AteSlip.Dish) -> Void = { _, _ in }
    /// A dish's photo on the menu was opened in the viewer (telemetry; the viewer is the shell's).
    var onMenuPhoto: () -> Void = {}

    var body: some View {
        ScrollView {
            // One lazy stack, and every visit is one of its own rows — never a `LazyVStack` of slips
            // inside a `VStack` under the menu, the shape that locked the Feed's main thread for
            // minutes (`FeedScreen`). The gaps the nested stacks used to give are each row's own
            // top padding.
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isSettled {
                    VStack(alignment: .leading, spacing: AteMetrics.loose) {
                        header
                        // A place that is not there, or could not be reached, is its one line and
                        // nothing under it.
                        if store.header.isFailure == false {
                            menu
                        }
                    }
                    .transition(.opacity)
                    if store.header.isFailure == false {
                        // `gap:12px` — one list, yours woven in first, `loose` under the menu.
                        visits
                            .transition(.opacity)
                        entries
                            .transition(.opacity)
                        if hasVisitsBand == false, hasEntriesBand == false {
                            // The list with nothing in it still held its place under the menu.
                            gap(AteMetrics.loose)
                        }
                    }
                } else if let name = store.previewName {
                    // The name the opening row printed, in its final place (round 6); the chips, the
                    // menu and a visit wait as still shapes at their sizes.
                    VStack(alignment: .leading, spacing: AteMetrics.loose) {
                        VStack(alignment: .leading, spacing: 10) {
                            AteExactText(text: name, style: .placeTitle, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                            PlaceChipsSkeleton()
                        }
                        MenuSkeleton()
                        SlipSkeleton(count: 1, hasByline: true)
                    }
                    .padding(.horizontal, AteMetrics.listGutter)
                    .transition(.opacity)
                } else {
                    PlacePageSkeleton()
                        .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .ateNavigationBar() // the glass back button (round 5)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        #if DEBUG
        .onAppear { DetailTimings.opened("place", hasPreview: store.previewName != nil) }
        .onChange(of: store.isSettled) { _, settled in if settled { DetailTimings.settled("place") } }
        #endif
    }

    // MARK: - Bands

    @ViewBuilder
    private var header: some View {
        switch store.header {
        case .loading:
            PlaceHeaderSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
        case .unavailable:
            // Deleted, or behind a block. Say that, and nothing else (design rule 1).
            AteEmptyState(title: "This place\nisn't here.")
                .ateEmptyPlacement(top: AteDetailPage.contentTop)
        case .unreachable:
            // The read never came back. Not the same as a place that is gone: this one gets a retry.
            AteUnreachableState { Task { await store.retry() } }
                .ateEmptyPlacement(top: AteDetailPage.contentTop)
            .accessibilityIdentifier("place.unreachable")
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 10) {
                AteExactText(text: summary.name, style: .placeTitle, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                facts
            }
            .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    /// `gap:6px` — the average, how many people, the cuisine, the suburb. Each one is drawn only
    /// when we hold it: a place with no cuisine on file shows three chips, never a placeholder
    /// (design rule 8).
    private var facts: some View {
        // Wraps onto a second line at the accessibility sizes rather than truncating a chip.
        AteFlow(spacing: 6) {
            ForEach(store.facts) { fact in
                switch fact {
                case .rating(let value):
                    AteChip(icon: .starFilled, title: value, iconSize: 14)
                        .accessibilityLabel("Rated \(value) out of 5")
                case .people(let value):
                    AteChip(icon: .feed, title: value, iconSize: 15)
                        .accessibilityLabel("\(value) people")
                case .word(let value):
                    AteChip(title: value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **What to order** — the ranked menu, on the one receipt this page carries. It wears the
    /// receipt palette — white in light, the plum slip in dark with light type (Eamon, 2026-09-26:
    /// the dimmed linen paper read as a hole in the ink ground) — and keeps its torn edge.
    @ViewBuilder
    private var menu: some View {
        switch store.menu {
        case .loading:
            MenuSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
        case .failed:
            EmptyView()
        case .ready where store.dishes.isEmpty:
            // Nobody has written up a dish here yet. Not an error, and not an instruction.
            AteEmptyState(title: "Nothing\nordered yet.")
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                Text("What to order")
                    .ateText(.receiptLabel)
                    .padding(.bottom, AteMetrics.regular)
                // Letter tiles chosen for the menu as it reads, so neighbours never match (round 4).
                let letters = DishLetter.neighbourly(store.dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
                    MenuDishRow(dish: dish, rank: index + 1, letter: letters[index], onPhoto: onMenuPhoto) {
                        // Everything this row printed, for the dish page to draw at once (round 6):
                        // the aggregate here IS the dish's, and its cover says whether it has photos.
                        DishPreviews.shared.note(DishPreview(
                            dishID: dish.dishID, name: dish.name,
                            restaurantID: store.restaurantID, restaurantName: store.name,
                            score: dish.score, photoURL: dish.coverURLString,
                            hasPhotos: dish.coverURLString != nil
                        ))
                        onDish(dish.dishID)
                    }
                        .task { await store.loadMoreDishesIfNeeded(after: dish) }
                }
            }
            .padding(.top, AteMetrics.loose)
            .padding(.horizontal, AteMetrics.loose)
            // `padding:16px 16px 6px`, plus the paper's own torn edge under it.
            .padding(.bottom, 6 + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateSlip()
            .ateTornPaper()
            .padding(.horizontal, AteMetrics.listGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("place.menu")
        }
    }

    /// **Your visits** — the viewer's own entries here, on the same dish-first slip as everyone
    /// else's and ahead of them, each signed "You". No band, no icon, no rules: a place you have never
    /// been to simply has none of these.
    @ViewBuilder
    private var visits: some View {
        if hasVisitsBand {
            slips(store.visits, identifier: "place.visit", lead: AteMetrics.loose)
        }
    }

    /// Everybody else's visits here, newest first — `gap:12px` under yours, or `loose` under the
    /// menu when you have none.
    @ViewBuilder
    private var entries: some View {
        let lead = hasVisitsBand ? AteMetrics.placeSlipGap : AteMetrics.loose
        switch store.entries.phase {
        case .loading:
            SlipSkeleton(count: 1, hasByline: true)
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, lead)
        case .empty, .signedOut:
            EmptyView()
        case .failed(let message):
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, lead)
        case .ready:
            slips(store.entries, identifier: "place.slip", lead: lead)
        }
    }

    /// Whether your visits hold a place in the list — even before they have loaded, as their own
    /// stack did.
    private var hasVisitsBand: Bool { store.hasVisits }

    /// Whether everybody else's do.
    private var hasEntriesBand: Bool {
        switch store.entries.phase {
        case .empty, .signedOut: false
        case .loading, .failed, .ready: true
        }
    }

    // MARK: - Pieces

    /// A list's slips as rows of the page's lazy stack: `lead` above the first, `gap:12px` between.
    /// A list with no slips yet still holds its place, as its own stack used to.
    @ViewBuilder
    private func slips(_ list: EntryListStore, identifier: String, lead: CGFloat) -> some View {
        if list.entries.isEmpty {
            gap(lead)
        }
        ForEach(list.entries) { entry in
            EntrySlip(
                slip: EntrySlipPresentation.placeVisit(entry),
                onOpen: { onOpen(entry) },
                onProfile: entry.isMine ? nil : { onProfile(entry.authorID) },
                onSave: entry.isMine ? nil : { onSave(entry, $0) },
                // No `onPlace`, and no foot line to carry one: every slip here is at *this*
                // place, so a pin would be a door back into the room it is already in.
                onDish: { onDish($0.dishID) },
                identifier: identifier
            )
            .task { await list.loadMoreIfNeeded(after: entry) }
            .padding(.top, entry.id == list.entries.first?.id ? lead : AteMetrics.placeSlipGap)
            .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    /// An empty row `height` tall — the space an empty stack used to take in the page.
    private func gap(_ height: CGFloat) -> some View {
        Color.clear.frame(height: 0).padding(.top, height)
    }
}

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
            if rank > 1 { AteDashedLine(opacity: 0.25) }
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

/// The header before it has arrived — the shape of a name and its chips, not a spinner.
private struct PlaceHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 220, height: 40)
            PlaceChipsSkeleton()
        }
        .accessibilityHidden(true)
    }
}

/// The header's chips before they have arrived, at the chips' own height.
private struct PlaceChipsSkeleton: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach([64.0, 58.0, 82.0], id: \.self) { width in
                Capsule()
                    .fill(AtePalette.automatic.hairline)
                    .frame(width: width, height: AteMetrics.chipHeight)
            }
        }
        .accessibilityHidden(true)
    }
}

/// …and the menu, drawn as the paper it is waiting for.
private struct MenuSkeleton: View {
    var body: some View {
        MenuSkeletonLines()
            .padding(.top, AteMetrics.loose)
            .padding(.horizontal, AteMetrics.loose)
            .padding(.bottom, 6 + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateSlip()
            .ateTornPaper()
            .accessibilityHidden(true)
    }
}

/// The skeleton's lines, reading the slip's own hairline so they sit on the receipt in both modes.
private struct MenuSkeletonLines: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(palette.hairline)
                .frame(width: 96, height: 11)
                .padding(.bottom, AteMetrics.regular)
            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 0) {
                    if index > 0 { AteDashedLine(opacity: 0.25) }
                    HStack(spacing: AteMetrics.regular) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.hairline)
                            .frame(width: 48, height: 48)
                            .padding(.leading, 18 + AteMetrics.regular)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.hairline)
                            .frame(width: 150, height: 16)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 66)
                }
            }
        }
    }
}

/// **The whole page before any of it has arrived** — the header, the menu and a visit, as the still
/// shapes they are waiting for (round 4: staged loading, no shimmer). Everything fills in at once.
private struct PlacePageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            PlaceHeaderSkeleton()
            MenuSkeleton()
            SlipSkeleton(count: 1, hasByline: true)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .accessibilityHidden(true)
    }
}

/// Where a pushed detail page's content begins on the screen: the 60 content top, the 44 back
/// arrow, and the page's 2 — what its "isn't here" and "couldn't reach Ate" are centred from.
enum AteDetailPage {
    static let contentTop: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.hairspace
}
