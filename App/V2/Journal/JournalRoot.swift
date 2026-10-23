import AteKit
import SwiftUI
import TipKit

/// **The Journal tab's root** — your record, under the wordmark.
///
/// One native bar row: the wordmark leading and one glass group trailing (the bell with its count,
/// search, the filter). Under it the slips, a month's name scrolling with them over its first slip. Scrolled,
/// the wordmark gives way to the month you are in. The filter is one sheet; while a filter is on its
/// chips sit under the bar, each with ✕. (Saved is its own tab; the calendar was cut for launch.)
/// The header is glass (`lighter-header.html`, B): the bar, the switch and the chips step away
/// together while you scroll down and come back on any scroll up.
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
    /// The bug's Feedback sheet (`feedback.html`), testers only.
    @State var isSendingFeedback = false
    @State var feedbackToast: String?
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
        // The switch is part of the header (22 Oct), pinned under its row, never half under it
        // (build 88), with the filter's chips beneath it on the Journal; the shelf scrolls under
        // all of it. Searching, the header steps away and the search screen covers the shelf.
        .ateGlassRootHeader(
            title: .wordmark,
            hidden: isSearching ? 1 : barHidden,
            showsApart: showsBug,
            apart: { bug },
            controls: { controls },
            accessory: {
                VStack(spacing: 0) {
                    shelfSwitch
                    if shelf == .journal { activeChips }
                }
            }
        )
        // Another shelf starts with its header showing.
        .onChange(of: shelf) { _, _ in barHidden = 0 }
        .sheet(isPresented: $isFiltering) { filterSheet }
        .sheet(isPresented: $isSendingFeedback) {
            FeedbackSheet(app: app) { feedbackToast = "Report sent. Thank you." }
        }
        .ateToast($feedbackToast)
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
            Task { await stores.photos.load() }
        }
        // Photos just posted with an entry: their sittings leave the count.
        .onReceive(NotificationCenter.default.publisher(for: .ateSuggestionPhotosWrittenUp)) { _ in
            Task { await stores.photos.load() }
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
            if isEmpty == false { AteTips.firstPostWritten() }
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

    /// The bug, apart from the group (`feedback.html` A): TestFlight and Debug builds only, signed in,
    /// never in an App Store build.
    private var showsBug: Bool {
        #if DEBUG || BETA
        app.hasSession
        #else
        false
        #endif
    }

    private var bug: some View {
        Button { isSendingFeedback = true } label: {
            AteIcon.bug.view(size: AteGlassDiscMetrics.glyph)
        }
        .accessibilityLabel("Send feedback")
        .accessibilityIdentifier("journal.feedback")
    }

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
        // First run's second tip: the rest of the roll waits here, once there is an entry to show for it.
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

    /// The bell's tip, while there is an entry and the roll holds more meals waiting.
    private var bellTip: BellTip? {
        let waiting = stores.photos.count
        guard waiting >= 1, journal.entries.isEmpty == false else { return nil }
        return BellTip(meals: waiting)
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
