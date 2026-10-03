import AteKit
import SwiftUI

/// **`Main`** — home. The logo, the Journal | Saved segment, the calendar, the filter chips, and your
/// entries newest first — under a large divider for each month, each slip carrying its own day at the
/// right of its foot line.
///
/// Journal is the app's front door (PRODUCT.md decision 1): you write for yourself, and the record
/// you keep is the first thing you see. Saved lives beside it because a dish you meant to eat belongs
/// next to the dishes you did.
///
/// Round 7: the filter is a row of chips — Newest · Rating · City · Date — each opening its own small
/// sheet (``JournalChipSheet``). The range, the city and the months are one choice shared by the two
/// shelves, so a filter set on one is still on when the other is chosen. Mid-list, the compact header
/// names the month you are in and carries the chips that are on. The calendar button, or a pinch on
/// the list, zooms out to the month and then the year (``JournalCalendarView``); a day brings you
/// back to it.
struct JournalScreen: View {
    let store: JournalStore
    /// The shelf beside it. Held by the shell rather than this screen, because a save made in the
    /// feed has to be able to tell it to reload.
    let saved: SavedDishesStore
    /// Bumped when the Journal tab is tapped while already current.
    var scrollToTopSignal = 0
    /// How many recent photos are waiting to be written up — the header badge. Zero hides it, which
    /// is also what no photo-library permission looks like (`MainEmpty` draws the button unbadged).
    var photoCount = 0
    let onCompose: () -> Void
    let onOpen: (EntryCard) -> Void
    var onSuggestions: () -> Void = {}
    /// A slip's pin line and its dish rows — the same doors the feed's slips carry.
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    /// A saved row's two doors: the place head, and the dish itself.
    var onSavedPlace: (UUID) -> Void = { _ in }
    var onSavedDish: (SavedDish) -> Void = { _ in }
    /// The bookmark on a saved row: it only ever unsaves.
    var onUnsave: (SavedDish) -> Void = { _ in }

    enum Shelf: Hashable {
        case journal, saved
    }

    @State var shelf: Shelf = {
        #if DEBUG
        return JournalDebugLaunch.opensSaved ? .saved : .journal
        #else
        return .journal
        #endif
    }()
    /// The chip whose sheet is up.
    @State var openChip: BrowseChip?
    /// Bumped by every change to what the list is — a filter, a sort, a chip cleared, the other
    /// shelf — so the new list starts at its top, under the header and its chips. Nothing about the
    /// layout gets it there by itself: a lazy list keeps its offset while its rows are replaced.
    @State var listChanged = 0
    /// Bumped when the other shelf is chosen: a jump to the top, without the scroll animating.
    @State var shelfChanged = 0
    /// The month of the slip at the top of the screen — the compact header's title.
    @State var topMonth: AteMonth?
    /// The header's height on the page, measured: it wraps at the accessibility sizes.
    @State var chromeHeight: CGFloat = AteMetrics.contentTop + JournalHeader.row
    /// The calendar, when it is up — the month or the year — and the month it is on.
    @State var calendarLevel: BrowseEvents.CalendarLevel?
    @State var calendarMonth = AteMonth.containing(Date())

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                list
                    .opacity(calendarLevel == nil ? 1 : 0)
                    .allowsHitTesting(calendarLevel == nil)
                    .accessibilityHidden(calendarLevel != nil)
                if calendarLevel != nil {
                    calendar(proxy: proxy)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .ateAnimation(AteMotion.calendarZoom, value: calendarLevel)
        }
        .onChange(of: scrollToTopSignal) { _, _ in calendarLevel = nil }
    }

    private var list: some View {
        ScrollView {
            // One lazy stack, and every slip — or saved dish, or month divider — is one of its own
            // rows: never a `LazyVStack` of slips inside a `VStack` under the header, the shape that
            // locked the Feed's main thread for minutes (`FeedScreen`). The compact header reads the
            // slips' ids off this stack, so it is the scroll-target layout.
            LazyVStack(alignment: .leading, spacing: 0) {
                chrome
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
                    // The shelf's fade is the shelf's: a filter changes the query and the phase in
                    // one go, and its chips change at once, as they always have.
                    .animation(nil, value: store.phase)
                shelfContent
            }
            .scrollTargetLayout()
            // Fingers together on the list zooms out to its month (round 7).
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                guard shelf == .journal, calendarLevel == nil,
                      value.magnification < AteCalendarMetrics.pinchOut else { return }
                openCalendar(via: .pinch)
            })
            // Loading is the column of skeleton slips, still; the entries replace it in one fade.
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            // Design rule 10: the last slip runs off under the tab bar rather than stopping dead
            // above it.
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.2) { visible in
            noteTopMonth(visible)
        }
        // The logo and the segment scroll away on the way down; on the way up the compact header
        // comes back — the month you are in, or the shelf's name, the chips that are on, and the
        // calendar. A re-tap scrolls to the page's true top.
        .ateTabRootHeader(scrollToTop: scrollToTopSignal + listChanged, jumpToTop: shelfChanged) {
            compactHeader
        }
        // Round 5 (Eamon: "the Journal/Saved tab doesn't need to animate like that"): the other
        // shelf is simply there, at its top — no scroll animating back up to it.
        .onChange(of: shelf) { _, _ in shelfChanged += 1 }
        .task { await store.loadIfNeeded() }
        // Read ahead, so the City sheet rises with its cities in it (#83's rule).
        .task { await store.loadCitiesIfNeeded() }
        .task { await saved.loadCitiesIfNeeded() }
        // The Saved shelf loads when it is chosen, and stops if it is left mid-read.
        .task(id: shelf) {
            if shelf == .saved { await saved.loadIfNeeded() }
        }
        .ateSheet(item: $openChip, name: "journal_chip", prepare: { chip in
            if chip == .city { await loadCitiesIfNeeded() }
        }, content: { chip in
            chipSheet(chip)
        })
        .task { await openDebugState() }
    }

    /// The header — logo, the Journal | Saved segment, the photo stack, the calendar, and the chips —
    /// at the top of the page. Mid-list, the compact header stands in for it.
    private var chrome: some View {
        JournalHeader(
            shelf: $shelf,
            photoCount: photoCount,
            filters: filters,
            cityName: cityName,
            onSuggestions: onSuggestions,
            onCalendar: { openCalendar(via: .button) },
            onChip: open,
            onClearChip: clear
        )
    }

    /// `JournalScrolled`: the month you are in ("August 2026") — or, where the list does not run
    /// through time, the shelf's name — the chips that are on, and the calendar.
    private var compactHeader: some View {
        let month = shelf == .journal && store.query.sort.isChronological && store.phase == .ready ? topMonth : nil
        return AteCompactHeader(
            title: month?.name() ?? (shelf == .journal ? "Journal" : "Saved"),
            subtitle: month.map { String($0.year) }
        ) {
            HStack(spacing: AteCompactHeaderMetrics.controlGap) {
                let active = chips.filter { filters.isActive($0) }
                ViewThatFits(in: .horizontal) {
                    activeChips(active)
                    activeChips(Array(active.prefix(1)))
                    Color.clear.frame(width: 0, height: 0)
                }
                JournalCalendarButton { openCalendar(via: .button) }
            }
        }
    }

    private func activeChips(_ active: [BrowseChip]) -> some View {
        HStack(spacing: AteFilterChipMetrics.spacing) {
            ForEach(active) { chip in
                AteFilterChip(
                    title: filters.title(of: chip, cityName: chip == .city ? cityName : nil),
                    isActive: true,
                    identifier: "journal.compact.chip.\(chip.rawValue)",
                    onOpen: { open(chip) },
                    onClear: { clear(chip) }
                )
            }
        }
        .fixedSize()
    }

    /// `MainEmpty`: `padding:16px 12px 110px; gap:22px; flex:1` — the first-day state sits 22 under
    /// the chips, centred on the one line every empty state shares (``AteEmptyPlacement``).
    static let firstDayGap: CGFloat = 22
    /// Where a shelf's empty state begins on the screen — Journal and Saved alike: under the header
    /// as it was drawn (the status bar, then the header's own measured height).
    var emptyTop: CGFloat { AteScreen.safeArea.top + chromeHeight + Self.firstDayGap }

    // MARK: - The top month

    private func noteTopMonth(_ visible: [UUID]) {
        guard let top = store.entries.first(where: { visible.contains($0.id) }) else { return }
        let month = AteMonth.containing(top.createdAt)
        if month != topMonth { topMonth = month }
    }

    // MARK: - The shelves

    /// Pull to refresh reloads whichever shelf is showing — the gesture belongs to the screen, and
    /// the screen is two lists.
    private func refresh() async {
        // The shelf's cities move with it: a pull reads them again too.
        switch shelf {
        case .journal:
            Task { await store.loadCities() }
            await store.refresh()
        case .saved:
            Task { await saved.loadCities() }
            await saved.refresh()
        }
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .journal:
            journalShelf
        case .saved:
            // `Saved.dc.html` parts the chips from the first place head by the column's own 14, and
            // the head carries its own 18 on top of that. The shelf is rows of this page's stack, so
            // it puts that margin on its first row itself.
            SavedScreen(
                store: saved,
                emptyTop: emptyTop,
                top: saved.phase == .ready || saved.phase == .loading ? AteMetrics.slipGap : Self.firstDayGap,
                onClear: { apply(BrowseFilters(sort: filters.sort)) },
                onPlace: onSavedPlace,
                onDish: onSavedDish,
                onUnsave: onUnsave
            )
        }
    }

    /// Loading is the column of skeleton slips, still; the entries replace it in one fade.
    @ViewBuilder
    private var journalShelf: some View {
        switch store.phase {
        case .loading:
            SlipSkeleton().ateCardWidth()
                .padding(.top, AteMetrics.slipGap)
                .transition(.opacity)
        case .empty:
            if store.query.hasFilters {
                firstDay(LegacyEmptyState(title: "Nothing\nlike that.", actionTitle: "Clear") {
                    // Clear is every chip: the order, the range, the city, the months.
                    apply(BrowseFilters())
                })
            } else {
                firstDay(LegacyEmptyState(
                    title: "Nothing\non the tab.", actionTitle: "Write your first", action: onCompose
                ))
            }
        case .signedOut:
            firstDay(LegacyEmptyState(title: "Nobody's\nsigned in."))
        case .failed:
            firstDay(AteUnreachableState { Task { await store.refresh() } })
        case .ready:
            slips
                .transition(.opacity)
        }
    }

    /// `MainEmpty` — the state, centred in the page under the chips. No paper: an empty journal
    /// has not printed anything, so it does not wear the receipt.
    private func firstDay(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: emptyTop)
            .padding(.top, Self.firstDayGap)
    }

    /// The slips, as rows of the page's own lazy stack (see `body`), each `slipGap` under the row
    /// before it — and over the first slip of each month, its divider (`Main`: 22 over it, 10 under;
    /// the first one straight under the chips, the first slip straight under it).
    ///
    /// The gap is **its own row**, not padding on the slip: the compact header asks which slips are
    /// 20% on screen (`onScrollTargetVisibilityChange`), and a slip's row has to be exactly the slip
    /// for that answer to be the one it has always been.
    @ViewBuilder
    private var slips: some View {
        let dividers = JournalMonthDividers.dividers(for: store.entries, sort: store.query.sort)
        let first = store.entries.first?.id
        ForEach(store.entries) { entry in
            if let month = dividers[entry.id] {
                monthDivider(month)
                    .accessibilityIdentifier("journal.month.\(month.year)-\(month.month)")
                    .padding(.top, entry.id == first ? 0 : AteMetrics.slipGap)
                    .id(Self.dividerID(entry.id))
            }
            if entry.id != first || dividers[entry.id] == nil {
                Color.clear
                    .frame(height: AteMetrics.slipGap)
                    .accessibilityHidden(true)
                    .id(Self.gapID(entry.id))
            }
            EntrySlip(
                slip: EntrySlipPresentation.journal(entry),
                onOpen: { onOpen(entry) },
                onPlace: onPlace,
                onDish: { onDish($0.dishID) }
            )
            .task { await store.loadMoreIfNeeded(after: entry) }
            // Its own task, so the row scrolling away cancels the prefetch with it.
            .task { await AtePrefetch.photos(after: entry, in: store.entries) }
            .ateCardWidth()
            .id(entry.id)
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.regular)
                .padding(.top, AteMetrics.slipGap)
                .ateCardWidth()
        }
    }

    static func dividerID(_ entry: UUID) -> String { "\(entry.uuidString).month" }
    static func gapID(_ entry: UUID) -> String { "\(entry.uuidString).gap" }

    /// A month's divider: its count from `journal_days`, and with a filter on, how many of them the
    /// filter keeps (`my_entries_count`).
    private func monthDivider(_ month: AteMonth) -> some View {
        let days = store.calendarDays
        let query = store.query
        return AteMonthDivider(
            title: month.name(),
            year: String(month.year),
            count: JournalMonthDividers.count(
                total: days.total(of: month),
                filtered: days.filteredCount(of: month, query: query),
                isFiltered: query.hasFilters
            )
        )
        .task(id: "\(month.year)-\(month.month)-\(query.hashValue)-\(days.revision)") {
            await days.loadYear(month.year)
            if query.hasFilters { await days.loadFilteredCount(month, query: query) }
        }
    }
}

/// **The journal's one header control**: a chip-coloured disc with the photo-stack mark, and a coral
/// badge carrying how many recent photos are waiting to be written up. It opens `Suggestions`.
struct PhotoStackButton: View {
    var count: Int
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteIcon.photoStack.view(size: 20)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                // The chrome's glass, like every top-corner button (round 5) — not the chip disc.
                .ateCornerGlass()
                .foregroundStyle(palette.fg)
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 photo to write up" : "\(count) photos to write up")
        .accessibilityIdentifier("journal.suggestions")
    }

    @ViewBuilder
    private var badge: some View {
        if count >= 1 {
            Text(count.formatted())
                .ateText(.badge)
                .foregroundStyle(AteColor.ink)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(AteColor.coral, in: .capsule)
                .offset(x: 3, y: -3)
        }
    }
}
