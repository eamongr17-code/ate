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
    /// The month of the slip at the top of the screen, and whether the list is moving.
    @State private var topMonth: JournalPeriod?
    @State private var isScrolling = false
    /// The header and the segment have scrolled away — the marker has somewhere to sit.
    @State private var isPastHeader = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    segmentRow
                        .padding(.top, AteMetrics.loose)
                        .id(Self.topAnchor)
                    filters
                    shelfContent
                }
                // Design rule 10: the last slip runs off under the tab bar rather than
                // stopping dead above it.
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
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
            .task { await store.loadIfNeeded() }
            .sheet(isPresented: $isFiltering) {
                JournalFilterSheet(initial: store.query, places: store.places, periods: periods) { query in
                    apply(query)
                }
            }
        }
    }

    private static let topAnchor = "journal.top"
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
                    Task { await store.loadPlaces() }
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
            // centres its state in the page below (`firstDay`).
            journalShelf.padding(.top, store.phase == .ready || store.phase == .loading
                ? AteMetrics.slipGap : Self.firstDayGap)
        case .saved:
            // `Saved.dc.html` parts the segment from the first place head by the column's own 14,
            // and the head carries its own 18 on top of that. An empty shelf is a slip, and gets
            // the margin a slip gets.
            SavedScreen(
                store: saved,
                emptyTop: Self.emptyTop,
                onPlace: onSavedPlace,
                onDish: onSavedDish,
                onUnsave: onUnsave
            )
            .padding(.top, saved.phase == .ready || saved.phase == .loading ? AteMetrics.slipGap : Self.firstDayGap)
        }
    }

    /// Loading is the column of skeleton slips, still; the entries replace it in one fade.
    @ViewBuilder
    private var journalShelf: some View {
        Group {
            switch store.phase {
            case .loading:
                SlipSkeleton().ateCardWidth()
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
        .ateAnimation(AteMotion.fillIn, value: store.phase)
    }

    /// `MainEmpty` — the state, centred in the page under the segment. No paper: an empty journal
    /// has not printed anything, so it does not wear the receipt.
    private func firstDay(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: Self.emptyTop)
    }

    private var slips: some View {
        LazyVStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(store.entries) { entry in
                EntrySlip(
                    slip: EntrySlipPresentation.journal(entry),
                    onOpen: { onOpen(entry) },
                    onPlace: onPlace,
                    onDish: { onDish($0.dishID) }
                )
                .id(entry.id)
                .task { await store.loadMoreIfNeeded(after: entry) }
                // Its own task, so the row scrolling away cancels the prefetch with it.
                .task { await AtePrefetch.photos(after: entry, in: store.entries) }
            }
            if let message = store.inlineErrorMessage {
                Text(message)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AteMetrics.regular)
            }
        }
        .scrollTargetLayout()
        .ateCardWidth()
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
                .background(palette.chip, in: .circle)
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
