import AteKit
import SwiftUI

/// **The Saved tab's root** — the dishes you kept, under their places, beneath the standard root
/// header. One control in the bar's glass group, the filter (the Journal's sheet, less the order);
/// while a filter is on its chips sit under the bar, each with ✕. An unsave here leaves the row at
/// once, with an Undo pill above the tab bar for four seconds.
struct SavedRoot: View {
    let router: TabRouter<SavedStores>
    let app: AppModel

    init(router: TabRouter<SavedStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    @State private var isCollapsed = false
    @State private var isFiltering = false
    /// Bumped by every change to what the list is, so the new list starts at its top: a lazy list
    /// keeps its offset while its rows are replaced.
    @State private var listChanged = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let top = "saved.top"

    private var saved: SavedDishesStore { router.stores.saved }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: router.scrollToTop) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.top, anchor: .top) }
                }
                .onChange(of: listChanged) { _, _ in
                    var jump = Transaction(animation: nil)
                    jump.disablesAnimations = true
                    withTransaction(jump) { proxy.scrollTo(Self.top, anchor: .top) }
                }
        }
        .accessibilityIdentifier("v2.root.saved")
        .ateGround()
        .ateRootToolbar(
            title: .text(V2Tab.saved.title),
            inline: AteInlineTitle(title: V2Tab.saved.title),
            isCollapsed: isCollapsed
        ) {
            controls
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            activeChips
                .ateGround()
        }
        .overlay(alignment: .bottom) { undo }
        .sheet(isPresented: $isFiltering) { filterSheet }
        .task {
            await saved.loadIfNeeded()
            app.services.analytics(SocialEvents.savedViewed())
        }
        // Read ahead, so the filter sheet rises with its cities in it.
        .task { await saved.loadCitiesIfNeeded() }
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.top)
                rows
            }
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .ateRootCollapse($isCollapsed)
        .refreshable {
            Task { await saved.loadCities() }
            await saved.refresh()
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch saved.phase {
        case .loading:
            ForEach(0..<SavedMetrics.skeletonRows, id: \.self) { _ in
                AteSkeleton(kind: .dishRow)
                    .padding(.horizontal, AteMetrics.gutter)
            }
            .padding(.top, AteMetrics.regular)
        case .empty where saved.filter.isEmpty == false:
            emptyBand(AteEmptyState(line: "Nothing\nlike that.", pill: ("Clear", { apply(BrowseFilters()) })))
        case .empty:
            emptyBand(AteEmptyState(line: "Nothing saved\nyet."))
        case .signedOut:
            emptyBand(AteEmptyState(line: "Nobody's\nsigned in."))
        case .failed:
            emptyBand(AteEmptyState(line: "Couldn't\nreach Ate.", pill: ("Try again", { retry() })))
        case .ready:
            groups
        }
    }

    /// A state with nothing under it: the one empty anatomy, centred in the page.
    private func emptyBand(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical) { length, _ in
            max(length, SavedMetrics.emptyMinimum)
        }
    }

    private func retry() {
        Task { await saved.refresh() }
    }

    /// Each place a head, its dishes under it. The letter tiles are chosen for the shelf as it reads,
    /// top to bottom, so no two dishes one above the other share an accent.
    @ViewBuilder
    private var groups: some View {
        let shelfDishes = saved.groups.flatMap(\.dishes)
        let letters = Dictionary(
            zip(shelfDishes.map(\.id), DishLetter.neighbourly(shelfDishes.map { ($0.dishID, $0.dishName) })),
            uniquingKeysWith: { first, _ in first }
        )
        ForEach(saved.groups) { group in
            placeHead(group)
                .padding(.horizontal, AteMetrics.gutter)
            ForEach(group.dishes) { dish in
                AteDishRow(
                    photo: .dish(letters[dish.id] ?? DishLetter(dishID: dish.dishID, name: dish.dishName),
                                 cover: dish.dishCoverURL),
                    name: dish.dishName,
                    subtitle: dish.sourceUsername.map { "from @\($0)" },
                    score: dish.dishScore.map { .average($0) },
                    isFirst: dish.id == group.dishes.first?.id,
                    isSaved: true,
                    onSave: { Task { await app.saves.unsaveFromShelf(dish) } },
                    onOpen: { router.open(.dish(dish.dishID), from: .saved) }
                )
                .padding(.horizontal, AteMetrics.gutter)
                .task { await saved.loadMoreIfNeeded(after: dish) }
                .accessibilityIdentifier("saved.dish")
            }
        }
    }

    /// The place, its city, and the chevron onward to its page.
    private func placeHead(_ group: SavedDishGroup) -> some View {
        Button {
            router.open(.place(group.restaurantID), from: .saved)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(group.restaurantName)
                    .ateText(.slipPlace)
                    .foregroundStyle(AtePalette.automatic.fg)
                if let city = group.city {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                }
                Spacer(minLength: 0)
                AteIcon.chevron.view(size: SavedMetrics.chevron)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            .padding(.top, SavedMetrics.placeTop)
            .padding(.bottom, SavedMetrics.placeBottom)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("saved.place")
    }

    // MARK: - The bar

    /// The filter, once there is something to sort or while a filter is on.
    @ViewBuilder
    private var controls: some View {
        let hasSomethingToSort = saved.phase == .ready || saved.phase == .loading
        if hasSomethingToSort || filters.isFiltering(on: .saved) {
            AteGlassToggleItem(
                icon: .listFilter,
                label: "Filter",
                isOn: filters.isFiltering(on: .saved),
                identifier: "saved.filter"
            ) {
                openFilter()
            }
        }
    }

    // MARK: - Undo

    /// After an unsave on the shelf: one ink pill above the tab bar for four seconds — the row
    /// leaving is what happened, and this is the way back.
    @ViewBuilder
    private var undo: some View {
        if let dish = saved.undoable {
            AteInkPill(title: "Undo", size: .empty, identifier: "saved.undo") {
                Task { await app.saves.undoUnsaveFromShelf() }
            }
            .accessibilityLabel("Undo, put back \(dish.dishName)")
            .padding(.bottom, AteMetrics.regular)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: dish.dishID) {
                try? await Task.sleep(for: SavedMetrics.undoLifetime)
                guard Task.isCancelled == false else { return }
                saved.expireUndo(for: dish)
            }
        }
    }

    // MARK: - Filters

    /// What is on: the shelf's range, city and months (Saved has no order).
    private var filters: BrowseFilters {
        BrowseFilters(band: saved.filter.band, city: saved.filter.city, window: saved.filter.window)
    }

    private var cityName: String? {
        filters.city.map { AteCity.displayName(for: $0, in: saved.cities) }
    }

    /// Under the bar, only while a filter is on: each chip its value and an ✕.
    @ViewBuilder
    private var activeChips: some View {
        let active = filters.activeChips(on: .saved)
        if active.isEmpty == false {
            AteFilterChipRow(
                chips: active.map { chip in
                    AteFilterChipRow.Chip(
                        id: chip.rawValue,
                        title: filters.title(of: chip, cityName: chip == .city ? cityName : nil)
                    )
                },
                onOpen: { openFilter() },
                onClear: { chip in
                    guard let chip = BrowseChip(rawValue: chip.id) else { return }
                    app.services.analytics(BrowseEvents.chipCleared(chip, on: .saved))
                    apply(filters.clearing(chip))
                }
            )
            .padding(.vertical, AteMetrics.snug)
        }
    }

    private func openFilter() {
        app.services.analytics(BrowseEvents.filterOpened(on: .saved))
        isFiltering = true
    }

    private var filterSheet: some View {
        let saved = saved
        return JournalFilterSheet(
            shelf: .saved,
            initial: filters,
            cities: saved.cities,
            count: { draft in try await saved.count(draft.savedFilter) },
            onShow: { apply($0) }
        )
        .task { await saved.loadCitiesIfNeeded() }
    }

    /// The sheet's Show, or a chip cleared.
    private func apply(_ next: BrowseFilters) {
        let filter = next.savedFilter
        guard filter != saved.filter else { return }
        listChanged += 1
        Task {
            await saved.apply(filter)
            app.services.analytics(BrowseEvents.savedFiltered(filter, resultCount: saved.dishes.count))
        }
    }
}

enum SavedMetrics {
    /// An empty state never squeezes below this, however small the screen.
    static let emptyMinimum: CGFloat = 320
    static let skeletonRows = 6
    /// A place head: `padding:18px 0 10px`, its chevron 15.
    static let placeTop: CGFloat = 18
    static let placeBottom: CGFloat = 10
    static let chevron: CGFloat = 15
    /// How long the shelf's Undo stays open.
    static let undoLifetime = Duration.seconds(4)
}
