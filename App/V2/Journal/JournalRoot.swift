import AteKit
import SwiftUI
import TipKit

/// **The Journal tab's root** — your record, and your lists.
///
/// One header row (`journal-header.html` B, 24 Oct): "Journal  Lists" leading, two titles that are
/// the switch, and one glass group trailing (the bell with its count, search, the filter). Under it
/// the slips, a month's name scrolling with them over its first slip. The filter is one sheet; while a
/// filter is on its chips sit under the row, each with ✕. (Saved is its own tab; the calendar was cut
/// for launch; the testers' bug lives on the You tab.) The header is glass (`glass-header.html` 1):
/// the row and the chips step away together while you scroll down and come back on any scroll up.
struct JournalRoot: View {
    let router: TabRouter<JournalStores>
    let app: AppModel

    init(router: TabRouter<JournalStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    /// How far the glass header has stepped away, 0 to 1 (``SwiftUICore/View/ateRootBarHiding(_:)``).
    @State var barHidden: CGFloat = 0
    @State var isFiltering = false
    /// Bumped by every change to what the list is — a filter, a chip cleared — so
    /// the new list starts at its top: a lazy list keeps its offset while its rows are replaced.
    @State var listChanged = 0
    /// Journal | Lists — the pinned switch (`lists-notifications.html` §3).
    @State var shelf = JournalShelf.journal
    /// The Lists shelf's New list sheet, opened from the glass group.
    @State var isNamingList = false
    /// Journal search (`JournalRoot+Search`): the field over the header row while it is up.
    @State var isSearching = false
    @State var search: JournalSearchStore?
    @State var searchText = ""
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    static let top = "journal.top"

    var stores: JournalStores { router.stores }
    var journal: JournalStore { stores.journal }

    var body: some View {
        ScrollViewReader { proxy in
            shelfContent
                .onChange(of: router.scrollToTop) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.top, anchor: .top) }
                }
                .onChange(of: listChanged) { _, _ in jump(to: Self.top, proxy: proxy) }
        }
        .accessibilityIdentifier("v2.root.journal")
        .ateGround()
        // One row (`journal-header.html` B, 24 Oct): "Journal  Lists" as the title, the glass group
        // trailing, and on the Journal the filter's chips beneath; the shelf scrolls under all of it.
        // Searching, the header steps away and the search screen covers the shelf.
        .ateGlassRootHeader(
            hidden: isSearching ? 1 : barHidden,
            title: { shelfTitles },
            controls: { controls },
            accessory: {
                if shelf == .journal { activeChips }
            }
        )
        // Another shelf starts with its header showing.
        .onChange(of: shelf) { _, _ in barHidden = 0 }
        .sheet(isPresented: $isFiltering) { filterSheet }
        .overlay { searchOverlay }
        .task { await loadJournal() }
        // Read ahead, so the filter sheet rises with its cities in it.
        .task { await journal.loadCitiesIfNeeded() }
        // The photo count and the bell's tag count, read whenever the Journal is shown — the first
        // time included, so the count is not also read from a `.task` (it scans the camera roll).
        .onAppear {
            Task { await stores.photos.load() }
            guard app.hasSession else { return }
            Task { await app.notifications.refreshCount() }
        }
        // The Summary's one ask for photos was answered yes: the count can appear now.
        .onReceive(NotificationCenter.default.publisher(for: .atePhotoAccessGranted)) { _ in
            Task { await stores.photos.load(force: true) }
        }
        // Photos just posted with an entry: their sittings leave the count.
        .onReceive(NotificationCenter.default.publisher(for: .ateSuggestionPhotosWrittenUp)) { _ in
            Task { await stores.photos.load(force: true) }
        }
        // An entry changed after the composer closed — an edit's re-sort printing its new dishes, a
        // correction on its page: put that one entry in place.
        .onReceive(NotificationCenter.default.publisher(for: .ateV2EntryChanged)) { note in
            guard let card = note.object as? EntryCard else { return }
            journal.replace(card)
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
        // Somebody with an entry is past their first: the composer's Score and Place tips retire.
        .onChange(of: journal.entries.isEmpty, initial: true) { _, isEmpty in
            if isEmpty == false { AteTips.journalHasEntries() }
        }
    }

    /// The journal's read — and, the first time this launch, how long it took (`list_first_read`).
    private func loadJournal() async {
        let isFirst = journal.hasLoaded == false
        let started = ContinuousClock.now
        await journal.loadIfNeeded()
        guard isFirst, journal.hasLoaded, journal.phase != .signedOut else { return }
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        app.services.analytics(ShellEvents.listFirstRead(
            "journal", durationMilliseconds: milliseconds, fromCache: journal.drewFromCache
        ))
    }

    // MARK: - The bar

    /// Bell, search and filter, in one glass group (`lists-notifications.html` A1). The bell wears one
    /// coral count — unread "Ate with" tags plus photo sittings — and stays on an empty Journal, so a
    /// first entry can start from the camera roll. Search and the filter wait for something to find.
    @ViewBuilder
    private var controls: some View {
        AteGlassItem(icon: .bell, label: "Notifications", badge: inboxCount) {
            BellTip(meals: stores.photos.count).invalidate(reason: .actionPerformed)
            router.open(.notifications, from: .journal)
        }
        .accessibilityIdentifier("journal.notifications")
        // First run's bell tip: the meals in the roll wait here.
        .popoverTip(bellTip, arrowEdge: .top)
        if let openJournalSearch, hasSomethingToSort {
            AteGlassItem(icon: .search, label: "Search your journal", action: openJournalSearch)
                .accessibilityIdentifier("journal.search")
        }
        if shelf == .lists {
            newListItem
        } else if hasSomethingToSort || filters.isFiltering(on: .journal) {
            AteGlassToggleItem(
                icon: .listFilter,
                label: "Filter",
                isOn: filters.isFiltering(on: .journal),
                identifier: "journal.filter"
            ) {
                openFilter()
            }
        }
    }

    /// The magnifier's action (`JournalRoot+Search`). `nil` would hide it — never a dead button.
    var openJournalSearch: (() -> Void)? { openSearch }

    /// The bell's tip, while the roll holds meals waiting — on an empty Journal too, where the count
    /// is otherwise the only thing on the bell. Not while the Journal is still loading.
    var bellTip: BellTip? {
        let waiting = stores.photos.count
        guard waiting >= 1, journal.phase == .ready || journal.phase == .empty else { return nil }
        return BellTip(meals: waiting, hasEntries: journal.entries.isEmpty == false)
    }

    /// The bell's one number: unread tags plus photo sittings.
    private var inboxCount: Int {
        JournalInboxCount(
            ateWith: app.hasSession ? app.notifications.unreadCount : 0,
            photos: stores.photos.count
        ).total
    }

    private var hasSomethingToSort: Bool {
        journal.phase == .ready || journal.phase == .loading
    }

    // MARK: - Moving about

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

    /// Pull to refresh reloads the list, and its cities with it.
    func refresh() async {
        Task { await journal.loadCities() }
        await journal.refresh()
    }
}
