import AteKit
import SwiftUI

/// **The Saved tab's root** — the dishes you kept, each over its place, beneath the standard root
/// header. One control in the bar's glass group, the filter (the Journal's sheet, less the order);
/// while a filter is on its chips sit under the bar, each with ✕. An unsave here — the bookmark, or
/// a swipe on the row — leaves the row at once, with an Undo pill above the tab bar for four seconds.
struct SavedRoot: View {
    let router: TabRouter<SavedStores>
    let app: AppModel

    init(router: TabRouter<SavedStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    @State private var isCollapsed = false
    @State private var isFiltering = false
    /// The beta's + (``AteBeta``): a dish of your own.
    @State private var isAdding = false
    /// A dish of your own, opened.
    @State private var openedOwn: OwnSave?
    /// "I ate it" was tapped: the composer opens once the sheet has gone, never over it.
    @State private var eating: OwnSave?
    /// Bumped by every change to what the list is, so the new list starts at its top: a lazy list
    /// keeps its offset while its rows are replaced.
    @State private var listChanged = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let top = "saved.top"

    private var saved: SavedDishesStore { router.stores.saved }
    private var own: OwnSavesStore { app.ownSaves }

    /// Your own dishes join the shelf in the beta, and only while no filter is on: they have no
    /// score, and the filter sheet does not know them yet.
    private var showsOwn: Bool { AteBeta.isOn && saved.filter.isEmpty }

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
        .sheet(isPresented: $isAdding) { SavedAddSheet(app: app) }
        .sheet(item: $openedOwn, onDismiss: composeEaten) { save in
            SavedOwnSheet(save: save, app: app) { ateIt(save) }
        }
        .task {
            await saved.loadIfNeeded()
            app.services.analytics(SocialEvents.savedViewed())
        }
        .task {
            guard AteBeta.isOn else { return }
            await own.loadIfNeeded()
        }
        // Read ahead, so the filter sheet rises with its cities in it.
        .task { await saved.loadCitiesIfNeeded() }
    }

    // MARK: - The list

    /// A plain `List` rather than a lazy stack, so a row takes the native swipe to remove — the
    /// one a list's own rows take (``V2ListPage``) — beside its bookmark.
    private var list: some View {
        List {
            Color.clear
                .frame(height: 0)
                .listPlainRow()
                .id(Self.top)
            rows
        }
        .listStyle(.plain)
        // A list gives every row 44 at least, the zero-high top anchor included: that was a gap
        // over the first row (build 141).
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.section, for: .scrollContent)
        .ateRootCollapse($isCollapsed)
        .refreshable {
            Task { await saved.loadCities() }
            if AteBeta.isOn { Task { await own.refresh() } }
            await saved.refresh()
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch saved.phase {
        case .loading:
            ForEach(0..<SavedMetrics.skeletonRows, id: \.self) { index in
                AteSkeleton(kind: .dishRow)
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, index == 0 ? AteMetrics.regular : 0)
                    .listPlainRow()
            }
        case .empty where showsOwn && own.saves.isEmpty == false:
            groups
        case .empty where saved.filter.isEmpty == false:
            emptyBand(AteEmptyState(line: "Nothing\nlike that.", art: .search,
                pill: ("Clear", { apply(BrowseFilters()) })))
        case .empty:
            emptyBand(AteEmptyState(line: "Nothing saved\nyet.", art: .saved))
        case .signedOut:
            emptyBand(AteEmptyState(line: "Nobody's\nsigned in.", art: .printer))
        case .failed where showsOwn && own.saves.isEmpty == false:
            groups
        case .failed:
            emptyBand(AteEmptyState(line: "Couldn't\nreach Ate.", art: .torn, pill: ("Try again", { retry() })))
        case .ready:
            groups
        }
    }

    /// A state with nothing under it: the one empty anatomy, centred in the page.
    private func emptyBand(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical) { length, _ in
            max(length, SavedMetrics.emptyMinimum)
        }
        .listPlainRow()
    }

    private func retry() {
        Task { await saved.refresh() }
    }

    /// The dishes you kept, newest first — the dish leading each row, its place second (build 92: the
    /// place heads made the shelf a wall of text). The letter tiles are chosen down the shelf as it
    /// reads, so no two dishes one above the other share an accent.
    @ViewBuilder
    private var groups: some View {
        let rows = SavedShelf.rows(
            ate: saved.phase == .ready ? saved.dishes : [],
            own: showsOwn ? own.saves : [],
            ateHasReachedEnd: saved.phase != .ready || saved.hasReachedEnd
        )
        let letters = DishLetter.neighbourly(rows.map(Self.letterKey))
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            Group {
                switch row {
                case .ate(let dish): ateRow(dish, letter: letters[index], isFirst: index == 0)
                case .own(let save): ownRow(save, letter: letters[index], isFirst: index == 0)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, index == 0 ? AteMetrics.snug : 0)
            .listPlainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(SavedCopy.remove, role: .destructive) { remove(row) }
                    .tint(AteColor.destructive)
            }
            .accessibilityAction(named: SavedCopy.remove) { remove(row) }
        }
    }

    /// The bookmark and the swipe are the one remove: the row leaves, with the Undo pill.
    private func remove(_ row: SavedShelf.Row) {
        switch row {
        case .ate(let dish):
            if let pending = own.undoable { own.expireUndo(for: pending) }
            Task { await app.saves.unsaveFromShelf(dish) }
        case .own(let save):
            if let pending = saved.undoable { saved.expireUndo(for: pending) }
            Task { await own.remove(save) }
        }
    }

    private func ateRow(_ dish: SavedDish, letter: DishLetter, isFirst: Bool) -> some View {
        AteDishRow(
            photo: .dish(letter, cover: dish.dishCoverURL),
            name: dish.dishName,
            subtitle: Self.place(of: dish),
            score: dish.dishScore.map { .average($0) },
            isFirst: isFirst,
            isSaved: true,
            onSave: { remove(.ate(dish)) },
            onOpen: { router.open(.dish(dish.dishID), from: .saved) }
        )
        .task { await saved.loadMoreIfNeeded(after: dish) }
        .accessibilityIdentifier("saved.dish")
    }

    /// A dish you saved yourself: its mark where it came from, never a score; it opens its sheet.
    private func ownRow(_ save: OwnSave, letter: DishLetter, isFirst: Bool) -> some View {
        AteDishRow(
            photo: .dish(letter, cover: nil),
            name: save.dishName,
            subtitle: SavedOwnCopy.place(of: save),
            mark: save.source.mark,
            isFirst: isFirst,
            isSaved: true,
            onSave: { remove(.own(save)) },
            onOpen: { openedOwn = save }
        )
        .accessibilityIdentifier("saved.own")
    }

    private static func letterKey(_ row: SavedShelf.Row) -> (UUID, String) {
        switch row {
        case .ate(let dish): (dish.dishID, dish.dishName)
        case .own(let save): (save.id, save.dishName)
        }
    }

    /// "I ate it": the sheet goes, and once it has, the composer opens on the dish and its place.
    private func ateIt(_ save: OwnSave) {
        app.services.analytics(OwnSaveEvents.ateItTapped(source: save.source))
        eating = save
        openedOwn = nil
    }

    private func composeEaten() {
        guard let save = eating else { return }
        eating = nil
        guard app.gate.permitsWrite(.compose) else { return }
        app.compose(.ateIt(save))
    }

    /// The place, and its city after it.
    private static func place(of dish: SavedDish) -> String {
        guard let city = dish.restaurantCity, city.isEmpty == false else { return dish.restaurantName }
        return "\(dish.restaurantName), \(city)"
    }

    // MARK: - The bar

    /// The filter, once there is something to sort or while a filter is on.
    @ViewBuilder
    private var controls: some View {
        let hasSomethingToSort = saved.phase == .ready || saved.phase == .loading
        if AteBeta.isOn {
            AteGlassItem(icon: .compose, label: "Add a dish") { isAdding = true }
                .accessibilityIdentifier("saved.add")
        }
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
        if let save = own.undoable {
            AteInkPill(title: "Undo", size: .empty, identifier: "saved.undo") {
                Task { await own.undoRemove() }
            }
            .accessibilityLabel("Undo, put back \(save.dishName)")
            .padding(.bottom, AteMetrics.regular)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: save.id) {
                try? await Task.sleep(for: SavedMetrics.undoLifetime)
                guard Task.isCancelled == false else { return }
                own.expireUndo(for: save)
            }
        } else if let dish = saved.undoable {
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

enum SavedCopy {
    static let remove = "Remove"
}

enum SavedMetrics {
    /// An empty state never squeezes below this, however small the screen.
    static let emptyMinimum: CGFloat = 320
    static let skeletonRows = 6
    /// How long the shelf's Undo stays open.
    static let undoLifetime = Duration.seconds(4)
}
