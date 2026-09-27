import AteKit
import SwiftUI

/// **`Main`** — home. The logo, the Journal | Saved segment, and your entries newest first — each
/// slip carrying its own day at the right of its foot line, so the list needs no headings.
///
/// Journal is the app's front door (PRODUCT.md decision 1): you write for yourself, and the record
/// you keep is the first thing you see. Saved lives beside it because a dish you meant to eat belongs
/// next to the dishes you did.
///
/// Round 4: a light way to find an entry without a search — the filter control beside the segment
/// opens the one filter sheet (order, rating, diet, month, place; `my_entries`), the active filters
/// sit under it as removable pills, and quiet month markers show while the list scrolls.
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

    @State private var shelf: Shelf = {
        #if DEBUG
        return ComposerDebugLaunch.opensSaved ? .saved : .journal
        #else
        return .journal
        #endif
    }()
    @State private var isFiltering = false
    /// Bumped by every change to what the list is — a filter, a sort, a pill taken off, the other
    /// shelf — so the new list starts at its top, under the header and its pills. Nothing about the
    /// layout gets it there by itself: a lazy list keeps its offset while its rows are replaced.
    @State private var listChanged = 0
    /// The month of the slip at the top of the screen, and whether the list is moving.
    @State private var topMonth: JournalPeriod?
    @State private var isScrolling = false
    /// The header and the segment have scrolled away — the marker has somewhere to sit.
    @State private var isPastHeader = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { _ in
            ScrollView {
                // One lazy stack, and every slip — or saved dish — is one of its own rows: never a
                // `LazyVStack` of slips inside a `VStack` under the header, the shape that locked
                // the Feed's main thread for minutes (`FeedScreen`). The month markers read the
                // slips' ids off this stack, so it is the scroll-target layout.
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        segmentRow
                            .padding(.top, AteMetrics.loose)
                            .id(Self.topAnchor)
                        filters
                    }
                    // The shelf's fade is the shelf's: a filter changes the query and the phase in
                    // one go, and its pills arrive at once, as they always have.
                    .animation(nil, value: store.phase)
                    shelfContent
                }
                .scrollTargetLayout()
                // Loading is the column of skeleton slips, still; the entries replace it in one
                // fade. On the stack rather than around the shelf, so no wrapper stands between the
                // stack and its slips.
                .ateAnimation(AteMotion.fillIn, value: store.phase)
                // Design rule 10: the last slip runs off under the tab bar rather than
                // stopping dead above it.
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .onScrollPhaseChange { _, phase in
                isScrolling = phase.isScrolling
            }
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.2) { visible in
                noteTopMonth(visible)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.segmentBottom
            } action: { _, past in
                isPastHeader = past
            }
            .overlay(alignment: .top) { monthMarker }
            // The logo and the segment slide away on the way down and come straight back on the way
            // up; a re-tap scrolls to the page's true top (the segment anchor put the logo under the
            // status bar).
            .ateTabRootHeader(scrollToTop: scrollToTopSignal + listChanged) { chrome }
            .onChange(of: shelf) { _, _ in listChanged += 1 }
            .task { await store.loadIfNeeded() }
            // Read ahead, so the filter sheet opens with its places in it (round 5).
            .task { await store.loadPlaces() }
            // The Saved shelf loads when it is chosen, and stops if it is left mid-read — the task
            // the shelf's own view carried when it was one view rather than rows of this stack.
            .task(id: shelf) {
                if shelf == .saved { await saved.loadIfNeeded() }
            }
            .ateSheet(isPresented: $isFiltering, name: "journal_filter",
                      prepare: { await store.loadPlaces() }, content: {
                JournalFilterSheet(
                    initial: store.query,
                    places: store.places,
                    arePlacesLoaded: store.hasLoadedPlaces,
                    periods: periods
                ) { query in
                    apply(query)
                }
            })
        }
    }

    private static let topAnchor = "journal.top"

    /// The logo row, the segment and whatever filters ride under it — the header that floats: the
    /// same views as the top of the page, so the copy is the header to the point.
    private var chrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            segmentRow
                .padding(.top, AteMetrics.loose)
            filters
        }
    }

    /// `MainEmpty`: `padding:16px 12px 110px; gap:22px; flex:1` — the first-day state sits 22 under
    /// the segment, centred on the one line every empty state shares (``AteEmptyPlacement``).
    private static let firstDayGap: CGFloat = 22
    /// Where the segment ends on the page: the 60 content top, the 44 header, the 16 above the
    /// segment and the segment's own 44.
    private static let segmentBottom: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.loose
        + AteMetrics.segmentHeight + 2 * AteMetrics.tight
    /// Where a shelf's empty state begins on the screen — Journal and Saved alike.
    private static let emptyTop: CGFloat = segmentBottom + firstDayGap

    private var header: some View {
        HStack {
            AteWordmark()
            Spacer(minLength: AteMetrics.snug)
            PhotoStackButton(count: photoCount, action: onSuggestions)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .ateContentTop()
    }

    // MARK: - The segment and the filters

    /// The segment, and the filter control beside it (on the journal shelf only: the shelf of saves
    /// is not what it filters).
    private var segmentRow: some View {
        HStack(spacing: AteMetrics.snug) {
            AteSegments(
                options: [AteSegment(Shelf.journal, "Journal"), AteSegment(Shelf.saved, "Saved")],
                selection: $shelf
            )
            if shelf == .journal {
                AteFilterButton(isActive: store.query.isDefault == false, identifier: "journal.filter") {
                    AteTelemetry.record(BrowseEvents.filterOpened(on: .journal))
                    isFiltering = true
                }
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    /// The active filters, as removable pills under the segment. Nothing when nothing is on.
    @ViewBuilder
    private var filters: some View {
        if shelf == .journal, store.query.isDefault == false {
            AteActiveFilters(filters: store.query.activeFilters, identifier: "journal.filter.pill") { filter in
                apply(store.query.removing(filter))
            }
            .padding(.top, AteMetrics.regular)
        }
    }

    private var periods: [JournalPeriod] {
        JournalPeriods.offered(oldest: store.entries.last?.createdAt)
    }

    private func apply(_ query: JournalQuery) {
        guard query != store.query else { return }
        listChanged += 1
        Task {
            await store.apply(query)
            AteTelemetry.record(BrowseEvents.journalQueried(query, resultCount: store.entries.count))
        }
    }

    // MARK: - Month markers

    private func noteTopMonth(_ visible: [UUID]) {
        guard let top = store.entries.first(where: { visible.contains($0.id) }) else { return }
        topMonth = JournalPeriod.month(of: top.createdAt)
    }

    @ViewBuilder
    private var monthMarker: some View {
        let shows = isScrolling && isPastHeader
            && store.query.sort.isChronological && shelf == .journal
        ZStack {
            if shows, let topMonth {
                JournalMonthMarker(title: topMonth.title())
                    .transition(.opacity)
            }
        }
        .padding(.top, AteMetrics.tight)
        .animation(reduceMotion ? nil : .easeOut(duration: shows ? 0.15 : 0.6), value: shows)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: topMonth)
    }

    // MARK: - The shelves

    /// Pull to refresh reloads whichever shelf is showing — the gesture belongs to the screen, and
    /// the screen is two lists.
    private func refresh() async {
        switch shelf {
        case .journal: await store.refresh()
        case .saved: await saved.refresh()
        }
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .journal:
            // `Main` parts the segment from the first slip by the column's own 14; `MainEmpty`
            // centres its state in the page below (`firstDay`). Each case puts its own gap above
            // it: the shelf is rows of this page's stack, not one view in it.
            journalShelf
        case .saved:
            // `Saved.dc.html` parts the segment from the first place head by the column's own 14,
            // and the head carries its own 18 on top of that. An empty shelf is a slip, and gets
            // the margin a slip gets. The shelf is rows of this page's stack, so it puts that
            // margin on its first row itself.
            SavedScreen(
                store: saved,
                emptyTop: Self.emptyTop,
                top: saved.phase == .ready || saved.phase == .loading ? AteMetrics.slipGap : Self.firstDayGap,
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
                firstDay(AteEmptyState(title: "Nothing\nlike that.", actionTitle: "Clear") {
                    apply(JournalQuery(sort: store.query.sort))
                })
            } else {
                firstDay(AteEmptyState(
                    title: "Nothing\non the tab.", actionTitle: "Write your first", action: onCompose
                ))
            }
        case .signedOut:
            firstDay(AteEmptyState(title: "Nobody's\nsigned in."))
        case .failed:
            firstDay(AteUnreachableState { Task { await store.refresh() } })
        case .ready:
            slips
                .transition(.opacity)
        }
    }

    /// `MainEmpty` — the state, centred in the page under the segment. No paper: an empty journal
    /// has not printed anything, so it does not wear the receipt.
    private func firstDay(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: Self.emptyTop)
            .padding(.top, Self.firstDayGap)
    }

    /// The slips, as rows of the page's own lazy stack (see `body`), each `slipGap` under the row
    /// before it.
    ///
    /// The gap is **its own row**, not padding on the slip: the month markers ask which slips are
    /// 20% on screen (`onScrollTargetVisibilityChange`), and a slip's row has to be exactly the
    /// slip for that answer to be the one it has always been.
    @ViewBuilder
    private var slips: some View {
        ForEach(store.entries) { entry in
            Color.clear
                .frame(height: AteMetrics.slipGap)
                .accessibilityHidden(true)
                .id("\(entry.id.uuidString).gap")
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
                // System Liquid Glass, like every top-corner button (round 4) — not the chip disc.
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
