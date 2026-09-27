import AteKit
import SwiftUI

/// **`Search`** — the field, and whatever answers it.
///
/// Before a character is typed the tab is the field and **Nearby** (design rule 1: a screen with
/// nothing to say says nothing). The four scopes — Places, Dishes, People, Saved — appear once
/// typing starts, Instagram-style, on Places (round 4). Nearby is a list *ranked* by where the phone
/// is; nothing on it is attached to anything until it is tapped, which is design rule 8 with no
/// asterisk. The phone is asked through the same location path the composer's `PlaceSheet` uses
/// (`AteLocation`), and a refusal costs exactly that list.
///
/// The keyboard always has a way down (round 4 bug): a drag anywhere on the page, a tap anywhere
/// that is not the field or a control, and the Search key.
///
/// Every row goes somewhere that already exists: a place page, a dish page, somebody's profile. A
/// saved row is the shelf's own ``SavedDishRow``, bookmark and all, because a save is one action
/// wherever it is made.
struct SearchTabScreen: View {
    let store: SearchStore
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    /// The shared ``SaveAction``'s unsave. Returns whether it landed, so the row can come back on a
    /// refusal exactly as it does on the shelf.
    var onUnsave: (SavedDish) async -> Bool = { _ in true }

    @State private var location = AteLocation()
    /// Where the results start on the page — measured, so an empty state can be centred in what is
    /// left below the segments whatever size the title and field were drawn at.
    @State private var resultsTop: CGFloat = 0
    @State private var isFiltering = false
    /// A new set of filters starts the results at their top, with the pills that say what they are
    /// — the Journal's rule for its own filter sheet. Untyped, so it never holds a row.
    @State private var position = ScrollPosition()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFieldFocused: Bool
    /// The field's frame in the content, so a tap on it is never read as a tap "outside".
    @State private var fieldFrame: CGRect = .zero

    var body: some View {
        ScrollView {
            // `padding:62px 20px 0; gap:16px` — on the list gutter since round 4 (the Journal's 12).
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                Text("Search")
                    .ateText(.screenTitle)
                    .accessibilityAddTraits(.isHeader)
                // `Search.dc.html`: 52 tall, 18 in, on the chip rather than the field.
                AteSearchField(
                    prompt: "Places, dishes, people",
                    text: Binding(get: { store.query }, set: { store.query = $0 }),
                    height: 52,
                    horizontalPadding: 18,
                    background: AtePalette.automatic.chip,
                    textStyle: .searchField
                )
                .focused($isFieldFocused)
                .onSubmit { isFieldFocused = false }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(SearchTabScreen.contentSpace))
                } action: { fieldFrame = $0 }
                .accessibilityIdentifier("search.field")
                if store.showsScopes {
                    scopes
                        .transition(.opacity)
                    // The same active pills the Journal draws, under the control that set them.
                    if SearchFilters.applies(to: store.scope) {
                        AteActiveFilters(filters: store.filters.activeFilters, identifier: "search.filter.pill") {
                            store.setFilters(store.filters.removing($0))
                        }
                        // The pills scroll edge to edge; the page's own gutter is given back.
                        .padding(.horizontal, -AteMetrics.listGutter)
                        .transition(.opacity)
                    }
                }
                results
            }
            .ateAnimation(AteMotion.fillIn, value: store.showsScopes)
            .padding(.horizontal, AteMetrics.listGutter)
            .ateContentTop(62)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
            .frame(maxWidth: .infinity, minHeight: AteScreen.height, alignment: .top)
            // A tap on the page itself — not the field, not a row or a pill, which take their own
            // taps first — puts the keyboard away.
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .named(SearchTabScreen.contentSpace)) { point in
                guard fieldFrame.contains(point) == false else { return }
                isFieldFocused = false
            }
            .coordinateSpace(.named(SearchTabScreen.contentSpace))
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onChange(of: store.filters) { _, _ in
            withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .top) }
        }
        // A drag always moves the page (it bounces when the results are short), and a drag always
        // takes the keyboard with it.
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.immediately)
        .ateTabBarTracking() // the tab bar's shadow and re-expansion, as on every tab
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { isFieldFocused = false }
        }
        .sheet(isPresented: $isFiltering) { SearchFilterSheet(store: store) }
        .task { await store.start() }
        .task(id: store.scope) { await askWhereWeAre() }
        .task { openDebugState() }
    }

    /// The one thing this screen asks the phone for, and only while Nearby is what would be shown.
    /// A refusal costs exactly one list and is never mentioned again (no helper copy).
    private func askWhereWeAre() async {
        guard store.scope == .places else { return }
        // Until this answers, Places shows nothing under the field; a "no" keeps it that way.
        let coordinate = await location.current()
        await store.setOrigin(coordinate.map { SearchOrigin(latitude: $0.latitude, longitude: $0.longitude) })
    }

    // MARK: - Segments

    /// `gap:6px`, each pill 40 tall and 16 in; the current one is ink on the ground (`.ink`). The
    /// filter control sits at the end of the row — the Journal's, beside what it narrows — on the
    /// scopes a filter applies to (Places, Dishes).
    private var scopes: some View {
        HStack(alignment: .top, spacing: AteMetrics.snug) {
            // Wraps rather than truncating to "P…" once the type outgrows one line.
            AteFlow(spacing: AteMetrics.snug - 2) {
                ForEach(SearchScope.allCases) { scope in
                    SearchPill(
                        title: scope.title,
                        isOn: scope == store.scope,
                        identifier: "search.scope.\(scope.rawValue)"
                    ) { store.select(scope) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if SearchFilters.applies(to: store.scope) {
                AteFilterButton(isActive: store.filters.isEmpty == false, identifier: "search.filter") {
                    AteTelemetry.record(BrowseEvents.filterOpened(on: .search))
                    isFiltering = true
                }
                // The 44 disc centres on the scopes' 40 pill.
                .padding(.vertical, -2)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one section label the design draws, and only over the standing list.
            if store.isShowingNearby {
                Text("Nearby")
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .padding(.top, 6)
                    .padding(.bottom, AteMetrics.snug)
            }
            switch store.phase {
            case .idle:
                EmptyView()
            case .loading:
                SearchRowsSkeleton(
                    height: store.scope == .places || store.scope == .people
                        ? PlaceResultRow.height
                        : DishResultRow.height,
                    hasThumbnail: store.scope == .dishes || store.scope == .saved
                )
            case .empty:
                // An empty shelf with nothing typed is the shelf's own state, word for word; an
                // answer that found nothing is the search's.
                centred(AteEmptyState(
                    title: store.scope == .saved && store.isSearching == false
                        ? "Nothing saved\nyet."
                        : "Nothing\nfound."
                ))
            case .failed(let message):
                centred(AteEmptyState(title: message))
            case .ready:
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measured in the scrolled content's own space, so a pull or a bounce does not move it; the
        // content starts under the status bar, which is added back to put it on the page.
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(SearchTabScreen.contentSpace)).minY
        } action: { resultsTop = $0 + AteScreen.safeArea.top }
    }

    /// **The one position rule for a state with nothing under it** (``AteEmptyPlacement``): centred
    /// on the same screen line as every other empty state, measured from where the results begin.
    private func centred(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: resultsTop)
    }

    nonisolated private static let contentSpace = "search.content"

    @ViewBuilder
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            switch store.rows {
            case .places(let places):
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    PlaceResultRow(place: place) { open(place) }
                        .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .dishes(let dishes):
                let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    DishResultRow(dish: dish, letter: letters[index]) {
                        store.reportOpened()
                        onDish(dish.dishID)
                    }
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .people(let people):
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    PersonResultRow(person: person) {
                        store.reportOpened()
                        onProfile(person.userID)
                    }
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .saved(let saved):
                let letters = DishLetter.neighbourly(saved.map { ($0.dishID, $0.dishName) })
                ForEach(Array(saved.enumerated()), id: \.element.id) { index, dish in
                    SavedDishRow(
                        dish: dish,
                        letter: letters[index],
                        onTap: {
                            store.reportOpened()
                            onDish(dish.dishID)
                        },
                        onUnsave: {
                            Task { await store.unsave(dish) { await onUnsave(dish) } }
                        }
                    )
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            }
        }
    }

    /// A place row's tap. Every place on this tab is one we hold, so it opens by its UUID for free.
    private func open(_ place: PlaceResult) {
        store.reportOpened()
        onPlace(place.restaurantID)
    }

    /// A drive's starting state: the demo filters, and the sheet already open.
    private func openDebugState() {
        #if DEBUG
        if let filters = SearchDebugLaunch.startingFilters { store.setFilters(filters) }
        isFiltering = SearchDebugLaunch.opensFilter
        #endif
    }
}

#if DEBUG
#Preview("Search") {
    let service = InMemorySocialService()
    return SearchTabScreen(store: SearchStore(service: service))
    .ateGround()
}
#endif
