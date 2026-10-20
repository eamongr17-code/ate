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
        let store = PlacePageStore(
            restaurantID: placeID,
            source: context.source,
            places: services.placePages,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            previews: PlacePreviews.shared,
            explore: services.dishExplore,
            analytics: services.analytics
        )
        // The viewer's diet chips are on from the first frame: the menu never flashes unfiltered.
        store.useDiet(context.app.diet.codes)
        _store = State(initialValue: store)
    }

    var body: some View {
        ScrollViewReader { reader in
            page(reader)
        }
    }

    private func page(_ reader: ScrollViewProxy) -> some View {
        ScrollView {
            // One lazy stack, every visit its own row of it — never a lazy stack of slips inside
            // another stack (the shape that locked the old Feed's main thread).
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isSettled {
                    settled(reader)
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
        // A diet changed in Settings is this page's chips as well.
        .onChange(of: context.app.diet.codes) { _, codes in store.useDiet(codes) }
        // With chips on, read on until the paper has dishes to show (or the menu ends).
        .task(id: FilteredMenu(on: store.dietOn, isReady: store.menu == .ready)) { await store.fillFilteredMenu() }
        .accessibilityIdentifier("place.page")
    }

    // MARK: - Settled

    @ViewBuilder
    private func settled(_ reader: ScrollViewProxy) -> some View {
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
                header(summary.name, reader: reader)
                menu
            }
            .transition(.opacity)
            visits(store.visits, lead: AteMetrics.loose)
            others
        }
    }

    private func header(_ name: String, reader: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: V2PlaceMetrics.titleGap) {
            AteExactText(text: name, style: .placeTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .browseTitleBottom($titleBottom)
            if store.facts.isEmpty == false || store.dietCodes.isEmpty == false {
                let facts = store.facts.map { chip($0, reader: reader) }
                AteChipFlow(chips: facts + store.dietCodes.map(dietChip))
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    /// A fact as its chip: the average with the star, how many people with their mark, a word. Each
    /// is a door, as every tag in the app is (Eamon, 20 Oct): the average to the menu ranked by it,
    /// the people to their visits, the suburb to its tag page — the one a dish page's suburb opens.
    private func chip(_ fact: PlaceFact, reader: ScrollViewProxy) -> AteChipFlow.Chip {
        switch fact {
        case .rating(let value):
            let action = menuTarget.map { target -> () -> Void in
                { scroll(reader, to: target, kind: "rating") }
            }
            return AteChipFlow.Chip(id: fact.id, icon: .starFilled, title: value,
                                    accessibilityLabel: "Rated \(value) out of 5",
                                    identifier: "place.fact.rating", action: action)
        case .people(let value):
            let action = visitsTarget.map { target -> () -> Void in
                { scroll(reader, to: target, kind: "people") }
            }
            return AteChipFlow.Chip(id: fact.id, icon: .feed, title: value,
                                    accessibilityLabel: "\(value) people",
                                    identifier: "place.fact.people", action: action)
        case .word(let value):
            let action = store.suburbTag.map { tag -> () -> Void in { openSuburb(tag) } }
            return AteChipFlow.Chip(id: fact.id, title: value, identifier: "place.fact.suburb", action: action)
        }
    }

    /// The menu's paper, when there is one to go to.
    private var menuTarget: String? {
        store.menu == .ready && store.shownDishes.isEmpty == false ? V2PlaceAnchor.menu : nil
    }

    /// The first visit on the page: yours, else everybody else's.
    private var visitsTarget: UUID? {
        store.visits.entries.first?.id ?? store.entries.entries.first?.id
    }

    private func scroll(_ reader: ScrollViewProxy, to target: some Hashable, kind: String) {
        context.services.analytics(DetailEvents.placeFactOpened(kind: kind))
        AteHaptics.key()
        withAnimation(AteMotion.fillIn) { reader.scrollTo(target, anchor: .top) }
    }

    private func openSuburb(_ tag: DishTag) {
        context.services.analytics(DetailEvents.placeFactOpened(kind: "suburb"))
        context.open(.tag(DishTagRoute(tag)), from: .place)
    }

    /// One of the viewer's diet codes (`diet.html`: "Vegan"), on by default; a tap shows everything.
    private func dietChip(_ tag: DietTag) -> AteChipFlow.Chip {
        AteChipFlow.Chip(
            id: "diet:\(tag.rawValue)",
            title: tag.dietName,
            isOn: store.dietOff.contains(tag) == false,
            identifier: "place.diet.\(tag.rawValue)",
            action: {
                AteHaptics.key()
                store.toggleDiet(tag)
            }
        )
    }

    // MARK: - The Top Ate

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
        case .ready where store.shownDishes.isEmpty:
            // The diet chips let nothing through: what is true, in the menu's own words.
            AteEmptyState(
                line: "Nothing \(store.dietOn.map(\.eaterWord).joined(separator: ", "))\nordered yet.",
                art: .rail
            )
            .padding(.vertical, AteMetrics.section)
        case .ready:
            V2MenuPaper {
                let dishes = store.shownDishes
                let hidden = Set(store.dietOn)
                // Letter tiles chosen for the menu as it reads, so neighbours never match.
                let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    V2MenuRow(
                        dish: dish,
                        rank: index + 1,
                        photo: .dish(letters[index], cover: dish.coverURLString),
                        place: store.name,
                        // The chips that are on say their piece under the name, not beside it.
                        tags: dish.tags.filter { hidden.contains($0) == false },
                        dietSignals: store.dietSignals(for: dish),
                        onPhoto: { context.services.analytics(DetailEvents.menuPhotoOpened()) },
                        onOpen: { open(dish) }
                    )
                    .task { await store.loadMoreDishesIfNeeded(after: dish) }
                }
            }
            .id(V2PlaceAnchor.menu)
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

/// The menu's paper: "The Top Ate" as a section heading (Eamon, 18 Oct), the rows, Edge B under it.
private struct V2MenuPaper<Rows: View>: View {
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(FeedEditionCopy.topAte)
                .ateText(.feedSection)
                .accessibilityAddTraits(.isHeader)
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
    let place: String?
    let tags: [DietTag]
    let dietSignals: [DietSignal]
    let onPhoto: () -> Void
    let onOpen: () -> Void

    var body: some View {
        AteDishRow(
            photo: photo,
            name: dish.name,
            tags: tags,
            score: dish.score.map(AteScore.average),
            style: .menu(rank: rank),
            isFirst: rank == 1,
            onOpen: onOpen,
            onPhoto: onPhoto,
            photoByline: place,
            dietSignals: dietSignals
        )
        .accessibilityIdentifier("place.dish")
    }
}

/// Where the header's chips scroll the page to.
private enum V2PlaceAnchor {
    static let menu = "place.menu"
}

/// What the filtered menu's read-on waits on: the chips that are on, and the menu's first page.
private struct FilteredMenu: Equatable {
    let on: [DietTag]
    let isReady: Bool
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
                        .ateSkeletonSweep()
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
