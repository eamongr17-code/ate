import AteKit
import SwiftUI

/// **The Search tab's root.** The native title and search field, then one equal-width scope switch —
/// Dishes, Places, People, Saved, opening on Dishes — with the one filter disc at its end (round 5),
/// and the filter chips under it only while a filter is on. Nothing on that row moves when the scope
/// changes.
///
/// Before typing: your recent searches (Saved shows your whole shelf). Search never asks where the
/// phone is. Every row goes somewhere that already exists — a place, a dish, somebody's profile — and
/// a saved row carries the one bookmark, because a save is one action wherever it is made.
struct SearchRoot: View {
    let router: TabRouter<SearchStores>
    let app: AppModel

    @State private var isFiltering = false
    @State private var isCollapsed = false

    init(router: TabRouter<SearchStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    private var store: SearchStore { router.stores.search }
    private var recents: RecentSearches { router.stores.recents }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(SearchRootMetrics.top)
                    content
                }
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, AteMetrics.section)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .ateRootCollapse($isCollapsed)
            .onChange(of: router.scrollToTop) { _, _ in
                withAnimation { reader.scrollTo(SearchRootMetrics.top, anchor: .top) }
            }
            // A new set of filters starts the results at their top, under the chips that say what
            // they are.
            .onChange(of: store.filters) { _, _ in
                reader.scrollTo(SearchRootMetrics.top, anchor: .top)
            }
        }
        .safeAreaBar(edge: .top) { scopes }
        .ateGround()
        .ateRootToolbar(
            title: .text(V2Tab.search.title),
            inline: AteInlineTitle(title: V2Tab.search.title),
            isCollapsed: isCollapsed
        ) {
            EmptyView()
        }
        .searchable(
            text: Bindable(store).query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Dishes, places, people"
        )
        .onSubmit(of: .search) { recents.record(store.query, scope: store.scope) }
        .sheet(isPresented: $isFiltering) {
            V2SearchFilterSheet(store: store)
        }
        .task { await store.start() }
        // Read ahead, so the filter sheet rises with its cities and cuisines in it.
        .task { await store.loadCitiesIfNeeded() }
        .task { await store.loadCuisines() }
        .accessibilityIdentifier("v2.root.search")
    }

    // MARK: - The switch

    private var scopes: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            AteScopeSwitch(
                options: SearchRootMetrics.order.map { AteSegment($0, $0.title) },
                selection: Binding(get: { store.scope }, set: { store.select($0) }),
                isFilterOn: store.filters.isEmpty == false,
                isFilterAvailable: SearchFilters.applies(to: store.scope)
            ) {
                app.services.analytics(BrowseEvents.filterOpened(on: .search))
                isFiltering = true
            }
            .padding(.horizontal, AteMetrics.gutter)
            AteFilterChipRow(
                chips: store.filters.pills.map { AteFilterChipRow.Chip(id: $0.id, title: $0.title) },
                onOpen: { isFiltering = SearchFilters.applies(to: store.scope) },
                onClear: { chip in
                    guard let pill = store.filters.pills.first(where: { $0.id == chip.id }) else { return }
                    store.setFilters(store.filters.removing(pill))
                }
            )
        }
        .padding(.vertical, AteMetrics.snug)
    }

    // MARK: - Under the switch

    @ViewBuilder
    private var content: some View {
        if store.query.isEmpty, store.scope != .saved {
            recentSearches
        } else {
            switch store.phase {
            case .idle:
                EmptyView()
            case .loading:
                ForEach(0..<SearchRootMetrics.skeletonRows, id: \.self) { _ in
                    AteSkeleton(kind: .dishRow)
                }
            case .empty:
                empty
            case .failed(let message):
                AteEmptyState(line: message)
                    .browseFillsPage()
            case .ready:
                V2SearchResults(store: store, recents: recents, app: app, open: open)
            }
        }
    }

    /// Before typing: what was searched, newest first. A tap searches it again, in its scope.
    @ViewBuilder
    private var recentSearches: some View {
        ForEach(recents.items) { recent in
            AteRecentSearchRow(text: recent.text, isFirst: recent.id == recents.items.first?.id) {
                store.select(recent.scope)
                store.query = recent.text
                recents.record(recent.text, scope: recent.scope)
            }
        }
    }

    /// The app's one empty anatomy: an empty shelf with nothing typed is the shelf's own line; a
    /// search that found nothing offers to clear its filters when one is on.
    @ViewBuilder
    private var empty: some View {
        if store.scope == .saved, store.isSearching == false, store.filters.isEmpty {
            AteEmptyState(line: "Nothing saved\nyet.")
                .browseFillsPage()
        } else if store.filters.isEmpty || SearchFilters.applies(to: store.scope) == false {
            AteEmptyState(line: "Nothing\nfound.")
                .browseFillsPage()
        } else {
            AteEmptyState(line: "Nothing\nfound.", pill: (title: "Clear filters", action: { store.setFilters(.none) }))
                .browseFillsPage()
        }
    }

    /// A row's tap: the words that found it are a recent search, and the page goes on this tab.
    private func open(_ route: Route) {
        recents.record(store.query, scope: store.scope)
        store.reportOpened()
        router.open(route, from: .search)
    }
}

enum SearchRootMetrics {
    /// Dishes first: "this is a dish focused app" (Eamon, 3 Oct).
    static let order: [SearchScope] = [.dishes, .places, .people, .saved]
    static let top = "search.top"
    static let skeletonRows = 6
}
