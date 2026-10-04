import AteKit
import SwiftUI

/// **The Journal tab's root** — your record and the dishes you kept, under the wordmark.
///
/// One native bar row: the wordmark leading and one glass group trailing (photos with their count,
/// the calendar, the filter). Journal | Saved is a segmented control at the head of the list; under
/// it the slips, a month's name scrolling with them over its first slip. Scrolled, the wordmark gives
/// way to the month you are in. The filter is one sheet; while a filter is on its chips sit under
/// the bar, each with ✕. The calendar is a zoom of this same page — list, month, year: the calendar
/// control toggles list and month, a pinch steps all three, and a day tapped zooms back in to the
/// list at that day.
///
/// The range, the city and the months are one choice shared by the two shelves, so a filter set on
/// one is still on when the other is chosen; the order is the Journal's alone.
struct JournalRoot: View {
    let router: TabRouter<JournalStores>
    let app: AppModel

    init(router: TabRouter<JournalStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    enum Shelf: Hashable {
        case journal, saved
    }

    @State var shelf: Shelf = .journal
    @State var zoom: JournalZoom = .list
    /// The month the calendar is on.
    @State var calendarMonth = AteMonth.containing(Date())
    @State var isCollapsed = false
    @State var isFiltering = false
    /// The month of the slip at the top of the screen — the inline title, once scrolled.
    @State var topMonth: AteMonth?
    /// Bumped by every change to what the list is — a filter, a chip cleared, the other shelf — so
    /// the new list starts at its top: a lazy list keeps its offset while its rows are replaced.
    @State var listChanged = 0

    static let top = "journal.top"

    var stores: JournalStores { router.stores }
    var journal: JournalStore { stores.journal }
    var saved: SavedDishesStore { app.savedDishes }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                list
                    .opacity(zoom == .list ? 1 : 0)
                    .allowsHitTesting(zoom == .list)
                    .accessibilityHidden(zoom != .list)
                if zoom != .list {
                    zoomed(proxy: proxy)
                        .transition(.opacity.combined(with: .scale(scale: JournalMetrics.entranceScale)))
                }
            }
            .ateAnimation(AteMotion.calendarZoom, value: zoom)
            .onChange(of: router.scrollToTop) { _, _ in reselected(proxy: proxy) }
            .onChange(of: listChanged) { _, _ in jump(to: Self.top, proxy: proxy) }
        }
        .accessibilityIdentifier("v2.root.journal")
        .ateGround()
        .ateRootToolbar(
            title: .wordmark,
            inline: inlineTitle,
            isCollapsed: isCollapsed && zoom == .list
        ) {
            controls
        }
        .safeAreaInset(edge: .top, spacing: 0) { activeChips }
        .overlay(alignment: .bottom) { undo }
        .sheet(isPresented: $isFiltering) { filterSheet }
        .task { await journal.loadIfNeeded() }
        // Read ahead, so the filter sheet rises with its cities in it.
        .task { await journal.loadCitiesIfNeeded() }
        .task { await saved.loadCitiesIfNeeded() }
        // The Saved shelf loads when it is chosen, and stops if it is left mid-read.
        .task(id: shelf) {
            if shelf == .saved { await saved.loadIfNeeded() }
        }
        .task { await stores.photos.load() }
        // The Summary's one ask for photos was answered yes: the count can appear now.
        .onReceive(NotificationCenter.default.publisher(for: .atePhotoAccessGranted)) { _ in
            Task { await stores.photos.load() }
        }
        // Something queued has landed, or the composer closed on a new entry: read the list again.
        .onChange(of: app.outboxLanded) { _, _ in
            journal.invalidate()
            Task { await journal.loadIfNeeded() }
        }
        .onChange(of: app.isComposing) { _, isComposing in
            guard isComposing == false else { return }
            Task { await journal.refresh() }
        }
        .onChange(of: shelf) { _, now in
            // Saved has no dates: the calendar steps out.
            if now == .saved { zoom = .list }
            listChanged += 1
        }
    }

    // MARK: - The bar

    /// The month you are in, once the wordmark has scrolled away — or, where the list does not run
    /// through time, the shelf's name. The year joins a month only when it is not this one.
    private var inlineTitle: AteInlineTitle {
        let runsThroughTime = shelf == .journal && journal.query.sort.isChronological && journal.phase == .ready
        if runsThroughTime, let topMonth {
            let isThisYear = topMonth.year == AteMonth.containing(Date()).year
            return AteInlineTitle(title: topMonth.name(), subtitle: isThisYear ? nil : String(topMonth.year))
        }
        return AteInlineTitle(title: shelf == .journal ? "Journal" : "Saved")
    }

    /// Photos, calendar, filter — at most three, in one glass group. Calendar and filter wait until
    /// there is something to sort; photos stay, so a first entry can start from the camera roll.
    /// Saved has no calendar.
    @ViewBuilder
    private var controls: some View {
        AteGlassItem(icon: .photoStack, label: "Photos to write up", badge: stores.photos.count) {
            router.open(.suggestions, from: .journal)
        }
        .accessibilityIdentifier("journal.suggestions")
        if shelf == .journal, hasSomethingToSort {
            AteGlassToggleItem(
                icon: .calendar, label: "Calendar", isOn: zoom != .list, identifier: "journal.calendar"
            ) {
                step(to: zoom.toggled, via: .button)
            }
        }
        if hasSomethingToSort || filters.isFiltering(on: chipShelf) {
            AteGlassToggleItem(
                icon: .listFilter,
                label: "Filter",
                isOn: filters.isFiltering(on: chipShelf),
                identifier: "journal.filter"
            ) {
                openFilter()
            }
        }
    }

    private var hasSomethingToSort: Bool {
        switch shelf {
        case .journal: journal.phase == .ready || journal.phase == .loading
        case .saved: saved.phase == .ready || saved.phase == .loading
        }
    }

    // MARK: - Undo

    /// After an unsave on the shelf: one ink pill above the tab bar for four seconds — the row
    /// leaving is what happened, and this is the way back.
    @ViewBuilder
    private var undo: some View {
        if shelf == .saved, zoom == .list, let dish = saved.undoable {
            AteInkPill(title: "Undo", size: .empty, identifier: "saved.undo") {
                Task { await app.saves.undoUnsaveFromShelf() }
            }
            .accessibilityLabel("Undo, put back \(dish.dishName)")
            .padding(.bottom, AteMetrics.regular)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: dish.dishID) {
                try? await Task.sleep(for: JournalMetrics.undoLifetime)
                guard Task.isCancelled == false else { return }
                saved.expireUndo(for: dish)
            }
        }
    }

    // MARK: - Moving about

    /// The tab tapped again: a zoomed-out page comes back to the list; the list goes to its top.
    private func reselected(proxy: ScrollViewProxy) {
        guard zoom == .list else {
            zoom = .list
            return
        }
        withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
    }

    /// To a row at once, the scroll not animating.
    func jump(to id: some Hashable, proxy: ScrollViewProxy) {
        var jump = Transaction(animation: nil)
        jump.disablesAnimations = true
        withTransaction(jump) { proxy.scrollTo(id, anchor: .top) }
    }

    /// Opens the composer — the empty Journal's "Write your first", or a photo sitting's pen.
    func compose(_ presentation: ComposerPresentation) {
        guard app.gate.permitsWrite(.compose) else { return }
        AteHaptics.key()
        app.compose(presentation)
    }

    /// Pull to refresh reloads whichever shelf is showing, and its cities with it.
    func refresh() async {
        switch shelf {
        case .journal:
            Task { await journal.loadCities() }
            await journal.refresh()
        case .saved:
            Task { await saved.loadCities() }
            await saved.refresh()
        }
    }
}

enum JournalMetrics {
    /// The zoomed-out page arrives from a touch larger, as if the list had been pulled away.
    static let entranceScale: CGFloat = 1.04
    /// How long the shelf's Undo stays open.
    static let undoLifetime = Duration.seconds(4)
    /// The month's grid: `gap:6px`, a tile's corner 14, a standout day's ring 2.
    static let cellGap: CGFloat = 6
    static let tileCorner: CGFloat = 14
    static let ring: CGFloat = 2
    /// A written day with no photo: its numeral, and a 4pt ink dot under it.
    static let dot: CGFloat = 4
    static let dotBottom: CGFloat = 3
    /// Today, unwritten: its numeral on a 28pt ink disc.
    static let today: CGFloat = 28
    /// The numeral on a photo: `left:7px`, and 10 up from the tile's foot.
    static let numeralInset: CGFloat = 7
    static let numeralBottom: CGFloat = 10
    /// Between one month (or year) and the next in the calendar's vertical list. The mockup drew a
    /// single month; the gap is the screen's section spacing.
    static let monthGap: CGFloat = AteMetrics.section
    /// How long the calendar's list waits for its months to lay out before settling on the one it
    /// opens on.
    static let settle = Duration.milliseconds(60)
    static let settleSteps = 3
    /// The year: three columns of small months, 18 apart across and 16 down.
    static let yearColumns = 3
    static let yearColumnGap: CGFloat = 18
    static let yearRowGap: CGFloat = 16
    /// A small month's dots: 6 for a visit, 10 for a 5.0 or a 6, on a 13pt row, 1 apart.
    static let smallDot: CGFloat = 6
    static let largeDot: CGFloat = 10
    static let dotRow: CGFloat = 13
    static let dotGap: CGFloat = 1
    static let quietRim: CGFloat = 1
}
