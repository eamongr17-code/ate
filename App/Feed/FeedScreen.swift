import AteKit
import SwiftUI

/// **`Feed`** — the edition (round 8, `Main.dc.html`): a finite page you finish rather than a list that
/// never ends. The Top Ate, Because you loved…, New to the record, a shelf per craving and the row that
/// chooses them, a short run of the latest receipts, and then "You're caught up".
///
/// Dish-first everywhere: every row and card is a dish, saveable in place with the one ``SaveAction``;
/// the place is fine print. Your own entries are not here — they are the journal. Signed out, The Top
/// Ate and the latest receipts are; the personal sections are not.
struct FeedScreen: View {
    let edition: FeedEditionStore
    /// The latest receipts: the feed's own entries, capped (``FeedEditionStore/latestCap``).
    let latest: EntryListStore
    /// Which area the feed is about — the location chip, and what it reloads.
    var area: FeedAreaModel?
    /// Bumped when the Feed tab is tapped while already current.
    var scrollToTopSignal = 0
    var onOpen: (EntryCard) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    /// A slip's pin line and its dish rows — the same doors they are in the journal and on a profile.
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    /// A craving shelf's See all — the tag's own page (round 7), in the Feed's city.
    var onTag: (DishTagRoute) -> Void = { _ in }
    /// A latest receipt's dish row.
    var onSave: (EntryCard, AteSlip.Dish) -> Void = { _, _ in }
    /// A dish anywhere else on the page, and the section it was saved from.
    var onSaveDish: (FeedDish, FeedEvents.Section) -> Void = { _, _ in }
    var onViewed: () -> Void = {}

    @State private var isChoosingArea = false
    @State private var isChoosingCravings = false
    @State private var scrollToTopAfterArea = 0

    var body: some View {
        ScrollView {
            // The scroll view's content IS the lazy stack, and every section is one of its own rows —
            // never a lazy stack inside a `VStack` (the round-5 main-thread lock on a return mid-list).
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .ateAnimation(AteMotion.fillIn, value: edition.isSettled)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            async let cities: Void? = area?.loadCities()
            async let sections: Void = edition.refresh()
            await latest.refresh()
            _ = await (cities, sections)
        }
        // The title and the area scroll away on the way down; on the way up the compact header comes
        // back — "Feed", small, and the same location chip — on the one top frost (round 7).
        .ateTabRootHeader(scrollToTop: scrollToTopSignal + scrollToTopAfterArea) {
            AteCompactHeader(title: "Feed") {
                FeedLocationChip(model: area) { isChoosingArea = true }
            }
        }
        .task {
            onViewed()
            edition.beginVisit()
            // Both work near me out themselves (`FeedAreaModel.cityForFirstPage`), and are read at once.
            async let sections: Void = edition.loadIfNeeded()
            await latest.loadIfNeeded()
            await sections
            #if DEBUG
            if JournalDebugLaunch.opensFeedLocation { isChoosingArea = true }
            #endif
        }
        // Read ahead, so the location sheet rises with its cities in it (#83's rule).
        .task { await area?.loadCitiesIfNeeded() }
        .ateSheet(isPresented: $isChoosingArea, name: "feed_location",
                  prepare: { await area?.loadCitiesIfNeeded() }, content: {
            if let area {
                FeedLocationSheet(model: area) { choice in
                    Task { await choose(choice, in: area) }
                }
            }
        })
        .ateSheet(isPresented: $isChoosingCravings, name: "feed_cravings",
                  prepare: { await edition.loadOptionsIfNeeded() }, content: {
            CravingsSheet(store: edition) { next in
                Task { await edition.saveCravings(next) }
            }
        })
    }

    // MARK: - Where

    /// A pick from the sheet. Near me picked again is a retry — the phone may have moved, or the
    /// last read failed — so it reads again even when the city looks the same.
    private func choose(_ choice: FeedLocation, in area: FeedAreaModel) async {
        let changed = area.choose(location: choice)
        guard changed || choice == .nearMe else { return }
        scrollToTopAfterArea += 1
        async let sections: Void = edition.reload()
        await latest.reload()
        await sections
    }

    /// `padding:62px 16px 0 20px`, the title and the chip on one bottom line — then the page.
    private var header: some View {
        FeedLocationHeader(model: area) { isChoosingArea = true }
            .padding(.leading, FeedEditionMetrics.gutter)
            .padding(.trailing, FeedEditionMetrics.cardMargin)
            .ateContentTop(62)
    }

    /// Where an empty or unreachable state sits: under the header.
    private static let headerBottom: CGFloat = 62 + 42 + FeedEditionMetrics.headingTop

    // MARK: - The edition

    @ViewBuilder
    private var content: some View {
        if edition.isSettled == false {
            FeedSectionHeading(title: "The Top Ate", top: FeedEditionMetrics.topAteHeadingTop)
            TopAteSkeleton()
                .transition(.opacity)
        } else if edition.isEmpty, latest.entries.isEmpty, latest.phase != .loading {
            nothing
        } else {
            sections
            latestReceipts
            FeedCaughtUp()
                .onAppear { edition.sectionAppeared(.caughtUp) }
        }
    }

    /// Nobody has written anything here yet — or Ate could not be reached. Honest, and not an
    /// instruction; the cravings row still stands, so a follower can still choose.
    @ViewBuilder
    private var nothing: some View {
        switch latest.phase {
        case .failed:
            AteUnreachableState {
                Task {
                    async let sections: Void = edition.refresh()
                    await latest.refresh()
                    await sections
                }
            }
            .ateEmptyPlacement(top: Self.headerBottom)
        default:
            LegacyEmptyState(title: "Nobody's written\nanything yet.")
                .ateEmptyPlacement(top: Self.headerBottom)
        }
        if edition.showsChooseCravings {
            ChooseCravingsRow { isChoosingCravings = true }
        }
    }

    @ViewBuilder
    private var sections: some View {
        if edition.showsTopAte {
            FeedSectionHeading(title: "The Top Ate", top: FeedEditionMetrics.topAteHeadingTop,
                               identifier: "feed.section.topAte")
                .onAppear { edition.sectionAppeared(.topAte) }
            TopAteReceipt(lines: edition.topAte, onDish: open, onSave: { onSaveDish($0, .topAte) })
        }
        if edition.showsLoved, let loved = edition.loved {
            FeedSectionHeading(title: loved.title, identifier: "feed.section.loved")
                .onAppear { edition.sectionAppeared(.becauseYouLoved) }
            FeedDishCarousel(dishes: loved.dishes, identifier: "feed.loved", onDish: open) {
                onSaveDish($0, .becauseYouLoved)
            }
        }
        if edition.showsNew {
            FeedSectionHeading(title: "New to the record", identifier: "feed.section.new")
                .onAppear { edition.sectionAppeared(.newToRecord) }
            newRows
        }
        ForEach(edition.visibleShelves) { shelf in
            FeedSectionHeading(
                title: shelf.craving.title,
                onSeeAll: { onTag(shelf.craving.route(city: edition.city)) },
                identifier: "feed.shelf"
            )
            .onAppear { edition.sectionAppeared(.cravingShelf) }
            FeedDishCarousel(dishes: shelf.dishes, identifier: "feed.shelf.cards", onDish: open) {
                onSaveDish($0, .cravingShelf)
            }
        }
        if edition.showsChooseCravings {
            ChooseCravingsRow { isChoosingCravings = true }
        }
    }

    private var newRows: some View {
        let rows = edition.newDishes
        let letters = DishLetter.neighbourly(rows.map { ($0.dish.dishID, $0.dish.name) })
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                NewDishRow(
                    row: row, letter: letters[index], isLast: index == rows.count - 1,
                    onOpen: { open(row.dish) }, onSave: { onSaveDish(row.dish, .newToRecord) }
                )
            }
        }
        .padding(.horizontal, FeedEditionMetrics.gutter)
    }

    /// A short run of the feed's own slips — the same card as everywhere (`FeedTight`), capped.
    @ViewBuilder
    private var latestReceipts: some View {
        let entries = Array(latest.entries.prefix(FeedEditionStore.latestCap))
        if entries.isEmpty == false {
            FeedSectionHeading(title: "Latest receipts", identifier: "feed.section.latest")
                .onAppear { edition.sectionAppeared(.latestReceipts) }
            ForEach(entries) { entry in
                EntrySlip(
                    slip: EntrySlipPresentation.feed(entry),
                    onOpen: { onOpen(entry) },
                    onProfile: { onProfile(entry.authorID) },
                    onSave: { onSave(entry, $0) },
                    onPlace: onPlace,
                    onDish: { onDish($0.dishID) },
                    identifier: "feed.slip"
                )
                .task { await AtePrefetch.photos(after: entry, in: entries) }
                .padding(.top, entry.id == entries.first?.id ? 0 : FeedEditionMetrics.receiptGap)
                .padding(.horizontal, FeedEditionMetrics.cardMargin)
            }
        }
    }

    /// A dish's page, with what this row printed noted so it opens on it.
    private func open(_ dish: FeedDish) {
        DishPreviews.shared.note(DishPreview(
            dishID: dish.dishID, name: dish.name, restaurantID: dish.restaurantID,
            restaurantName: dish.restaurantName, score: dish.score, photoURL: dish.coverURLString
        ))
        onDish(dish.dishID)
    }
}
