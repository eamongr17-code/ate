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
    /// The map's question when Google Maps is on the phone: which app.
    @State private var mapChoice: PlaceMapLink?
    @Environment(\.openURL) private var openURL

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
        .ateTitleCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .ateCollapsingTitle(store.name ?? store.previewName, isCollapsed: isCollapsed)
        .ateRefreshable { await store.refresh() }
        .task { await store.load() }
        .placeMapsOpening($mapChoice, surface: "place", analytics: context.services.analytics)
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
                mapCard(summary)
                menu
            }
            .transition(.opacity)
            visits(store.visits, lead: AteMetrics.loose)
            others
        }
    }

    private func header(_ name: String, reader: ScrollViewProxy) -> some View {
        AtePageHeader(name, titleBottom: $titleBottom) {
            EmptyView()
        } line: {
            EmptyView()
        } below: {
            // No diet chip here: a restaurant is never labelled, only its dishes (Eamon, 23 Oct).
            // One line, the suburb giving way when it is long (Eamon, 27 Oct). The map card under
            // the header opens Maps; the pin is here only for a place the card has nothing for.
            AteChipFlow(chips: store.facts.map { chip($0, reader: reader) } + mapChips, isOneLine: true)
        }
    }

    // MARK: - Maps

    /// **Where it is** (`dish-page-place-map.html`, A, Eamon 28 Oct): the map and the full address
    /// under the header, on the same card a dish page shows. Tapping it opens Maps.
    @ViewBuilder
    private func mapCard(_ summary: PlaceSummary) -> some View {
        let link = PlaceMapLink(summary)
        if AtePlaceMapCard.shows(link, title: nil) {
            AtePlaceMapCard(link: link, onMap: { showMaps(link) })
                .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    /// The round pin (`place-pills-one-row.html`, 27 Oct), now only for a place with neither a point
    /// nor an address, which the card has nothing to draw for: every place still opens in Maps.
    private var mapChips: [AteChipFlow.Chip] {
        guard let summary = store.summary else { return [] }
        let link = PlaceMapLink(summary)
        guard AtePlaceMapCard.shows(link, title: nil) == false else { return [] }
        return [AteChipFlow.Chip(id: "map", icon: .place, title: "",
                                 accessibilityLabel: AtePlaceMapCardCopy.openInMaps(summary.name),
                                 identifier: "place.fact.map", action: { showMaps(link) })]
    }

    private func showMaps(_ link: PlaceMapLink) {
        PlaceMaps.show(link, choice: $mapChoice, surface: "place",
                       analytics: context.services.analytics, openURL: openURL)
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
            return AteChipFlow.Chip(id: fact.id, title: value, identifier: "place.fact.suburb",
                                    truncates: true, action: action)
        }
    }

    /// The menu's paper, when there is one to go to.
    private var menuTarget: String? {
        store.menu == .ready && store.dishes.isEmpty == false ? V2PlaceAnchor.menu : nil
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
            AteEmptyState(line: "Nothing\nordered yet.", art: .setting)
                .padding(.vertical, AteMetrics.section)
        case .ready:
            V2MenuPaper {
                let dishes = store.dishes
                // Letter tiles chosen for the menu as it reads, so neighbours never match.
                let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    V2MenuRow(
                        dish: dish,
                        rank: index + 1,
                        photo: .dish(letters[index], cover: dish.coverURLString),
                        place: store.name,
                        tags: dish.tags,
                        tagCounts: { tagCounts(for: dish.tags, in: dishes) },
                        onTagCounts: {
                            context.services.analytics(DietEvents.countsOpened(surface: .place, code: dish.tags.first))
                        },
                        onPhoto: { context.services.analytics(DetailEvents.menuPhotoOpened()) },
                        onOpen: { open(dish) }
                    )
                    .task { await store.loadMoreDishesIfNeeded(after: dish) }
                }
            }
            .id(V2PlaceAnchor.menu)
        }
    }

    /// **A row's pills, tapped** (`diet-more.html`): every dish on the menu wearing the same pill, with
    /// how many people of that diet logged it. One code: the dishes alone; several: each with its pill.
    private func tagCounts(for tags: [DietTag], in dishes: [MenuDish]) -> [AteDietCountsList.Row] {
        tags.flatMap { tag in
            dishes.filter { $0.tags.contains(tag) }.map { dish in
                let people = dish.dietCounts[tag]
                return AteDietCountsList.Row(
                    id: "\(tag.rawValue):\(dish.id)",
                    tag: tags.count > 1 ? tag : nil,
                    title: dish.name,
                    people: people > 0 ? "\(people)" : DietCountLine(tag: tag, people: nil).peopleText
                )
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
    let tagCounts: () -> [AteDietCountsList.Row]
    let onTagCounts: () -> Void
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
            tagCounts: tagCounts,
            onTagCounts: onTagCounts
        )
        .accessibilityIdentifier("place.dish")
    }
}

/// Where the header's chips scroll the page to.
private enum V2PlaceAnchor {
    static let menu = "place.menu"
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
/// chips, the map card, the menu and a visit as still shapes at their sizes.
private struct V2PlaceSkeleton: View {
    let name: String?
    @Binding var titleBottom: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            VStack(alignment: .leading, spacing: AtePageHeaderMetrics.belowGap) {
                if let name {
                    AteExactText(
                        text: name, style: .pageHeaderTitle, alignment: .leading, lineLimit: AtePageHeaderMetrics.lines
                    )
                    .accessibilityAddTraits(.isHeader)
                    .browseTitleBottom($titleBottom)
                } else {
                    AteSkeletonBar(width: V2PlaceMetrics.nameBar, height: V2PlaceMetrics.nameBarHeight,
                                   palette: .automatic)
                        .ateSkeletonSweep()
                }
                AteChipFlowSkeleton()
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AtePageHeaderMetrics.top)
            AtePlaceMapCardSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
            V2MenuPaper { V2MenuSkeletonRows() }
            AteSkeleton(kind: .entrySlip)
                .padding(.horizontal, AteMetrics.listGutter)
        }
    }
}

enum V2PlaceMetrics {
    static let skeletonRows = 3
    static let nameBar: CGFloat = 220
    static let nameBarHeight: CGFloat = 40
}
