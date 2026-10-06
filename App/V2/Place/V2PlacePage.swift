import AteKit
import SwiftUI

/// **A place: what to order there, and the visits written at it.** Menu first (contract §8): the
/// name and the facts we hold, the menu printed as the receipt with Edge B in rating order (unscored
/// dishes last with an empty slot, as the server sends them), then the visits with no heading —
/// yours first, each signed "You", then everybody else's, a bookmark on every dish row.
///
/// The page arrives whole (round 4): the name the opening row printed at once, the rest as still
/// shapes until the header, the menu and the visits are all in, then one fade. The average in the
/// header is read, never computed from the menu (data-model §1.2).
struct V2PlacePage: View {
    let placeID: UUID
    let context: V2PageContext

    @State private var store: PlacePageStore
    @State private var isCollapsed = false
    @State private var titleBottom: CGFloat = 0

    init(placeID: UUID, context: V2PageContext) {
        self.placeID = placeID
        self.context = context
        let services = context.services
        _store = State(initialValue: PlacePageStore(
            restaurantID: placeID,
            source: context.source,
            places: services.placePages,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            previews: PlacePreviews.shared,
            analytics: services.analytics
        ))
    }

    var body: some View {
        ScrollView {
            // One lazy stack, every visit its own row of it — never a lazy stack of slips inside
            // another stack (the shape that locked the old Feed's main thread).
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isSettled {
                    settled
                } else {
                    V2PlaceSkeleton(name: store.previewName, titleBottom: $titleBottom)
                        .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.section)
            .coordinateSpace(.named(BrowsePage.content))
        }
        .scrollIndicators(.hidden)
        .browseCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .browseBarTitle(store.name ?? store.previewName, isShown: isCollapsed)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .accessibilityIdentifier("place.page")
    }

    // MARK: - Settled

    @ViewBuilder
    private var settled: some View {
        switch store.header {
        case .loading:
            EmptyView()
        case .unavailable:
            // Deleted, or behind a block. Say that, and nothing else.
            AteEmptyState(line: "This place\nisn't here.", art: .torn)
                .browseFillsPage()
        case .unreachable:
            BrowsePage.unreachable { Task { await store.retry() } }
                .browseFillsPage()
        case .ready(let summary):
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                header(summary.name)
                menu
            }
            .transition(.opacity)
            visits(store.visits, lead: AteMetrics.loose)
            others
        }
    }

    private func header(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: V2PlaceMetrics.titleGap) {
            AteExactText(text: name, style: .placeTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .browseTitleBottom($titleBottom)
            if store.facts.isEmpty == false {
                AteChipFlow(chips: store.facts.map(Self.chip))
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    /// A fact as its chip: the average with the star, how many people with their mark, a word.
    private static func chip(_ fact: PlaceFact) -> AteChipFlow.Chip {
        switch fact {
        case .rating(let value):
            AteChipFlow.Chip(id: fact.id, icon: .starFilled, title: value,
                             accessibilityLabel: "Rated \(value) out of 5")
        case .people(let value):
            AteChipFlow.Chip(id: fact.id, icon: .feed, title: value, accessibilityLabel: "\(value) people")
        case .word(let value):
            AteChipFlow.Chip(id: fact.id, title: value)
        }
    }

    // MARK: - What to order

    @ViewBuilder
    private var menu: some View {
        switch store.menu {
        case .loading:
            V2MenuPaper { V2MenuSkeletonRows() }
        case .failed:
            EmptyView()
        case .ready where store.dishes.isEmpty:
            // Nobody has written up a dish here yet. Not an error, and not an instruction.
            AteEmptyState(line: "Nothing\nordered yet.", art: .rail)
                .padding(.vertical, AteMetrics.section)
        case .ready:
            V2MenuPaper {
                // Letter tiles chosen for the menu as it reads, so neighbours never match.
                let letters = DishLetter.neighbourly(store.dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
                    V2MenuRow(
                        dish: dish,
                        rank: index + 1,
                        photo: .dish(letters[index], cover: dish.coverURLString),
                        onPhoto: { context.services.analytics(DetailEvents.menuPhotoOpened()) },
                        onOpen: { open(dish) }
                    )
                    .task { await store.loadMoreDishesIfNeeded(after: dish) }
                }
            }
        }
    }

    private func open(_ dish: MenuDish) {
        // Everything this row printed, for the dish page to draw at once (round 6).
        DishPreviews.shared.note(DishPreview(
            dishID: dish.dishID, name: dish.name,
            restaurantID: store.restaurantID, restaurantName: store.name,
            score: dish.score, photoURL: dish.coverURLString,
            hasPhotos: dish.coverURLString != nil
        ))
        context.open(.dish(dish.dishID), from: .place)
    }

    // MARK: - The visits

    /// Everybody else's visits, newest first — 12 under yours, 16 under the menu when you have none.
    @ViewBuilder
    private var others: some View {
        let lead = store.hasVisits ? AteMetrics.placeSlipGap : AteMetrics.loose
        switch store.entries.phase {
        case .loading:
            AteSkeleton(kind: .entrySlip)
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
            visits(store.entries, lead: lead)
        }
    }

    /// One list's slips as rows of the page's lazy stack: `lead` above the first, 12 between.
    @ViewBuilder
    private func visits(_ list: EntryListStore, lead: CGFloat) -> some View {
        ForEach(list.entries) { entry in
            AteEntrySlip(
                slip: EntrySlipPresentation.placeVisit(entry),
                surface: .placeVisit,
                onOpen: { context.open(.entry(EntryRoute(entry)), from: .place) },
                onProfile: entry.isMine ? nil : { context.open(.profile(entry.authorID), from: .place) },
                onSave: entry.isMine ? nil : { dish in save(dish, from: entry) },
                // Every slip here is at this place: a pin would be a door back into this room.
                onDish: { context.open(.dish($0.dishID), from: .place) },
                identifier: entry.isMine ? "place.visit" : "place.slip"
            )
            .task { await list.loadMoreIfNeeded(after: entry) }
            .padding(.top, entry.id == list.entries.first?.id ? lead : AteMetrics.placeSlipGap)
            .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    /// The same save the Feed makes, from the same object: optimistic, broadcast, felt, counted.
    private func save(_ dish: AteSlip.Dish, from entry: EntryCard) {
        Task {
            await context.saves.toggle(dishID: dish.dishID, entryID: entry.id, isSaved: dish.isSaved, source: .place)
        }
    }
}

// MARK: - The menu

/// The menu's paper: "What to order" in the receipt's label, the rows, Edge B under it.
private struct V2MenuPaper<Rows: View>: View {
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What to order")
                .ateText(.receiptLabel)
                .padding(.bottom, AteMetrics.regular)
            rows
        }
        .padding(.top, AteMetrics.loose)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.tornEdgeHeight + AteMetrics.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ateSlip()
        .ateTornPaper()
        .padding(.horizontal, AteMetrics.listGutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("place.menu")
    }
}

/// One line of the menu: the kit's menu row. A cover photo is its own control and opens the photo
/// viewer (the kit's); a letter tile is part of the row and opens the dish.
private struct V2MenuRow: View {
    let dish: MenuDish
    let rank: Int
    let photo: AtePhoto
    let onPhoto: () -> Void
    let onOpen: () -> Void

    var body: some View {
        AteDishRow(
            photo: photo,
            name: dish.name,
            tags: dish.tags,
            subtitle: dish.peopleCount > 0 ? dish.peopleCount.formatted() : nil,
            subtitleIcon: dish.peopleCount > 0 ? .you : nil,
            score: dish.score.map(AteScore.average),
            style: .menu(rank: rank),
            isFirst: rank == 1,
            onOpen: onOpen,
            onPhoto: onPhoto
        )
        .accessibilityIdentifier("place.dish")
    }
}

/// The menu's rows before they arrive.
private struct V2MenuSkeletonRows: View {
    var body: some View {
        ForEach(0..<V2PlaceMetrics.skeletonRows, id: \.self) { _ in
            AteSkeleton(kind: .dishRow)
        }
    }
}

/// **The whole page before it has settled** — the name the opening row printed (or its bar), the
/// chips, the menu and a visit as still shapes at their sizes.
private struct V2PlaceSkeleton: View {
    let name: String?
    @Binding var titleBottom: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            VStack(alignment: .leading, spacing: V2PlaceMetrics.titleGap) {
                if let name {
                    AteExactText(text: name, style: .placeTitle, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .browseTitleBottom($titleBottom)
                } else {
                    AteSkeletonBar(width: V2PlaceMetrics.nameBar, height: V2PlaceMetrics.nameBarHeight,
                                   palette: .automatic)
                        .ateBreathing()
                }
                AteChipFlowSkeleton()
            }
            .padding(.horizontal, AteMetrics.listGutter)
            V2MenuPaper { V2MenuSkeletonRows() }
            AteSkeleton(kind: .entrySlip)
                .padding(.horizontal, AteMetrics.listGutter)
        }
    }
}

enum V2PlaceMetrics {
    /// The name over its chips: `gap:10px`.
    static let titleGap: CGFloat = 10
    static let skeletonRows = 3
    static let nameBar: CGFloat = 220
    static let nameBarHeight: CGFloat = 40
}
