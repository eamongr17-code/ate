import AteKit
import SwiftUI

/// **The Journal tab's root** — your record, under the wordmark.
///
/// One native bar row: the wordmark leading and one glass group trailing (the bell with its count,
/// search, the filter). Under it the slips, a month's name scrolling with them over its first slip. Scrolled,
/// the wordmark gives way to the month you are in. The filter is one sheet; while a filter is on its
/// chips sit under the bar, each with ✕. (Saved is its own tab; the calendar was cut for launch.)
struct JournalRoot: View {
    let router: TabRouter<JournalStores>
    let app: AppModel

    init(router: TabRouter<JournalStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    @State var isCollapsed = false
    @State var isFiltering = false
    /// The month of the slip at the top of the screen — the inline title, once scrolled.
    @State var topMonth: AteMonth?
    /// Bumped by every change to what the list is — a filter, a chip cleared — so
    /// the new list starts at its top: a lazy list keeps its offset while its rows are replaced.
    @State var listChanged = 0
    /// Journal | Lists — the pinned switch (`lists-notifications.html` §3).
    @State var shelf = JournalShelf.journal
    /// The Lists shelf's New list sheet, opened from the glass group.
    @State var isNamingList = false
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
        .ateRootToolbar(
            title: .wordmark,
            inline: inlineTitle,
            isCollapsed: isCollapsed
        ) {
            controls
        }
        // The switch, pinned under the bar on the ground, never half under it (build 88), with the
        // filter's chips beneath it on the Journal; the shelf scrolls below.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                shelfSwitch
                if shelf == .journal { activeChips }
            }
            .ateGround()
        }
        .sheet(isPresented: $isFiltering) { filterSheet }
        .task { await journal.loadIfNeeded() }
        // Read ahead, so the filter sheet rises with its cities in it.
        .task { await journal.loadCitiesIfNeeded() }
        .task { await stores.photos.load() }
        // The bell's tag count, read again whenever the Journal is shown (it moved here from You).
        .onAppear {
            Task { await stores.photos.load() }
            guard app.hasSession else { return }
            Task { await app.notifications.refreshCount() }
        }
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
    }

    // MARK: - The bar

    /// The month you are in, once the wordmark has scrolled away — or, where the list does not run
    /// through time, "Journal". The year joins a month only when it is not this one.
    private var inlineTitle: AteInlineTitle {
        if shelf == .lists { return AteInlineTitle(title: JournalShelf.lists.title) }
        let runsThroughTime = journal.query.sort.isChronological && journal.phase == .ready
        if runsThroughTime, let topMonth {
            let isThisYear = topMonth.year == AteMonth.containing(Date()).year
            return AteInlineTitle(title: topMonth.name(), subtitle: isThisYear ? nil : String(topMonth.year))
        }
        return AteInlineTitle(title: V2Tab.journal.title)
    }

    /// Bell, search and filter, in one glass group (`lists-notifications.html` A1). The bell wears one
    /// coral count — unread "Ate with" tags plus photo sittings — and stays on an empty Journal, so a
    /// first entry can start from the camera roll. Search and the filter wait for something to find.
    @ViewBuilder
    private var controls: some View {
        AteGlassItem(icon: .bell, label: "Notifications", badge: inboxCount) {
            router.open(.notifications, from: .journal)
        }
        .accessibilityIdentifier("journal.notifications")
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

    /// **Seam for the Journal search lane**: return the action that opens Journal search. While it is
    /// `nil` the magnifier is not drawn — never a dead button.
    var openJournalSearch: (() -> Void)? { nil }

    /// The bell's one number. TODO: use AteKit's `JournalInboxCount` once the Lists lane lands it.
    private var inboxCount: Int {
        NotificationsInbox.count(
            unreadTags: app.hasSession ? app.notifications.unreadCount : 0,
            photoSuggestions: stores.photos.count
        )
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
