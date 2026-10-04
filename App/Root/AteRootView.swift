import AteKit
import SwiftUI

/// **The app's root.** Resolves the build's environment into either the shell or a loud, readable
/// configuration error — a misconfigured checkout must explain itself, not crash.
struct AteRootView: View {
    let environment: Result<AteEnvironment, Error>
    /// Built once. The shell is rebuilt on every sign-out, and the services under it must not be —
    /// one client, one auth session, for the life of the process.
    @State private var services: AteServices?
    /// Bumped when a session ends, so the next person starts from a shell with nothing of the last
    /// one's in it: no journal, no shelf, no half-pushed stack.
    @State private var generation = 0

    init(environment: Result<AteEnvironment, Error>) {
        self.environment = environment
        _services = State(initialValue: (try? environment.get()).map { AteServices(environment: $0) })
    }

    var body: some View {
        resolved
            // Settings' Appearance, applied to the window so Welcome, every sheet and every cover
            // follow it too — not just the views under one modifier.
            .ateAppearance(AtePreferences.standard.appearance)
    }

    @ViewBuilder
    private var resolved: some View {
        switch environment {
        case .success:
            if let services {
                V2Root(services: services, onSessionEnded: { generation += 1 })
                    .id(generation)
            }
        case .failure(let error):
            ConfigurationErrorView(error: error)
        }
    }
}

/// **The shell**: the four tabs on the app's own glass bar, the `+` beside it that presents the
/// composer, and the navigation path the core loop travels on.
///
/// Journal is home (PRODUCT.md decision 1) and selection always starts there — no last tab is
/// persisted, because a journal you land in is a different product from a feed you land in.
@MainActor
struct AteShell: View {
    let services: AteServices
    /// Signed out, or deleted. The root throws this shell away and builds a clean one.
    var onSessionEnded: () -> Void = {}

    @State var tab: AteTab = .journal
    @State var journal: JournalStore
    /// Everyone else's entries, and the shelf a save fills. Held here rather than by the screens so
    /// a save made in the feed is already true on the shelf, and a block empties both at once.
    @State var feed: EntryListStore
    /// The Feed's edition (round 8) — its sections; `feed` above is its latest receipts.
    @State var feedEdition: FeedEditionStore
    @State var feedArea: FeedAreaModel // the feed's area, remembered per person
    @State var saved: SavedDishesStore
    /// The one save, made once and handed down — it holds which dishes are mid-flight.
    @State var saveAction: SaveAction
    /// Non-nil presents the composer, and carries what it was opened with.
    @State var composing: ComposerPresentation?
    /// The current tab's stack. Hoisted here so Done in the composer can land on the new entry, at
    /// the journal's root, rather than under whatever was open before.
    @State var path: [Route] = []
    /// Where each pushed destination was opened from — the `source` its view event carries.
    ///
    /// Kept beside the path rather than inside ``Route``: a route is an *identity*, and two pushes of
    /// one place from two screens must stay equal to `NavigationStack` and `path.contains`.
    @State var sources: [Route: DetailSource] = [:]
    /// How many recent photos are waiting to be written up — the journal header's badge. Only ever
    /// non-zero when the photo library has already been allowed; nothing here asks.
    @State var photoCount = 0
    /// Bumped when a tab's own item is tapped again — that tab's screen scrolls to the top. Per tab:
    /// every tab stays alive under the `TabView`, and one shared counter scrolled all of them.
    @State var scrollToTop: [AteTab: Int] = [:]
    /// What the tab bar shows — the current tab, full or minimised — read by every tab root's bar.
    /// `tab` stays the shell's own; this follows it (`AteShell+Tabs`).
    @State var chrome = AteTabChrome(current: .journal)
    /// The page's bottom safe area, read from layout (`AteShell+Tabs`).
    @State var bottomInset = AteTabBarMetrics.homeIndicatorInset
    @State var hasSession: Bool
    @State var isSigningIn = false
    /// Signed out, looking at the feed — and the ask that comes up when a browser tries to write.
    @State var gate: SessionGate
    /// Apple's display name, first sign-in only: the handle screen's suggestion.
    @State var firstRunName: String?
    /// The signed-in person's handle — a receipt is signed, so it is loaded once, here.
    @State var handle: String?
    /// The You tab, held here rather than by the screen so switching away and back does not re-read
    /// five RPCs — and so a pull-to-refresh on it is the only thing that does.
    @State var you: YouStore
    /// The Search tab, held here so its query, segment and pages survive a trip to another tab.
    @State private var search: SearchStore
    #if DEBUG
    /// `-ate-open summary/<id>`: the Summary a drive photographs without a composer to type into.
    @State var debugSummary: DebugSummary?
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init(services: AteServices, onSessionEnded: @escaping () -> Void = {}) {
        self.services = services
        self.onSessionEnded = onSessionEnded
        let gate = SessionGate(analytics: services.analytics)
        _gate = State(initialValue: gate)
        var hasSession = services.hasSession
        #if DEBUG
        let start = DebugStart(DebugLaunch.route) // where a drive's launch opens
        if start.showsWelcome { hasSession = false }
        #endif
        _hasSession = State(initialValue: hasSession)
        _journal = State(initialValue: JournalStore(
            entries: services.entries, deletions: services.entryDeletions, querying: services.journalQuerying
        ))
        let analytics = services.analytics
        let stores = FeedScreen.stores(services: services, isSignedIn: { [services] in services.hasSession })
        let feedStore = stores.latest
        _feedEdition = State(initialValue: stores.edition)
        _feedArea = State(initialValue: stores.area)
        // `feed_page_loaded` is reported where the page actually lands — a prefetched page and a
        // pulled one count the same, and a refresh cannot swallow its own first page by resetting
        // the count and filling it again in the same turn.
        feedStore.onPageLoaded = { page, items in
            analytics(SocialEvents.feedPageLoaded(page: page, itemCount: items))
        }
        _feed = State(initialValue: feedStore)
        _you = State(initialValue: YouStore(stats: services.stats))
        var searchScope = SearchScope.places
        var searchQuery = ""
        #if DEBUG
        if let opening = SearchDebugLaunch.start { (searchScope, searchQuery) = (opening.scope, opening.query) }
        #endif
        _search = State(initialValue: SearchStore(
            service: services.search,
            scope: searchScope,
            query: searchQuery,
            analytics: services.analytics,
            savedDishes: services.savedDishes
        ))
        let shelf = SavedDishesStore(saves: services.saves)
        _saved = State(initialValue: shelf)
        _saveAction = State(initialValue: SaveAction(
            saves: services.saves,
            analytics: services.analytics,
            shelf: shelf,
            broadcast: services.savedDishes,
            gate: gate
        ))
        #if DEBUG
        ComposerDebugLaunch.seedDraftIfRequested(into: services.drafts)
        _tab = State(initialValue: start.tab)
        _path = State(initialValue: start.path)
        _sources = State(initialValue: start.sources)
        if start.composes { _composing = State(initialValue: ComposerPresentation(origin: .tabBar)) }
        #endif
    }

    var body: some View {
        Group {
            if hasSession && owesHandle {
                firstRunHandle
            } else if hasSession || gate.isBrowsing {
                shell
                    .ateLinkShell() // a waiting link is pushed once the tabs are up
                    .task(id: hasSession) { await loadHandle() }
            } else {
                welcome(isPrompt: false)
            }
        }
        // "The first write asks for sign-in": Welcome again, over the feed, with its link as Not Now.
        .fullScreenCover(isPresented: $gate.isAsking) { welcome(isPrompt: true) }
        .environment(gate)
        // ate://entry/<id>, on every screen the shell shows — Welcome and the handle step too.
        .ateEntryLinks(linkSituation) { openLinkedEntry($0, browseFirst: $1) }
        .task { await autoSignInIfRequested() }
        #if DEBUG
        .task(id: hasSession) { await finishDebugLaunch() }
        #endif
        // An entry that could not be sent is still the person's. The outbox is worked on every
        // return to the app, and anything that lands refreshes the journal under it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await drainOutbox() }
        }
    }

    var shell: some View { tabShell }

    private var current: some View { screen(for: tab) }

    @ViewBuilder
    func screen(for tab: AteTab) -> some View {
        switch tab {
        case .journal:
            JournalScreen(
                store: journal,
                saved: saved,
                scrollToTopSignal: scrollToTop[.journal, default: 0],
                photoCount: photoCount,
                onCompose: { openComposer(.journalEmpty) },
                onOpen: { open(.entry($0)) },
                onSuggestions: { open(.suggestions) },
                onPlace: { open(.place($0), from: .journal) },
                onDish: { open(.dish($0), from: .journal) },
                onSavedPlace: { open(.place($0), from: .saved) },
                onSavedDish: { open(.dish($0.dishID), from: .saved) },
                // The shelf's own bookmark. Only a round trip the server accepted is announced
                // to the rest of the app or counted — the store puts its row back on a refusal.
                onUnsave: { dish in
                    Task { await saveAction.unsaveFromShelf(dish) }
                }
            )
            .task { await countPhotos() }
            // The Summary's one ask for photos was answered yes: the button can appear now.
            .onReceive(NotificationCenter.default.publisher(for: .atePhotoAccessGranted)) { _ in
                Task { await countPhotos() }
            }
        case .feed:
            FeedScreen(
                edition: feedEdition,
                latest: feed,
                area: feedArea,
                scrollToTopSignal: scrollToTop[.feed, default: 0],
                onOpen: { open(.entry($0)) },
                onProfile: { open(.profile($0)) },
                onPlace: { open(.place($0), from: .feed) },
                onDish: { open(.dish($0), from: .feed) },
                onTag: { open(.tag($0)) },
                onSave: { entry, dish in
                    Task {
                        await saveAction.toggle(
                            dishID: dish.dishID,
                            entryID: entry.id,
                            isSaved: dish.isSaved,
                            source: .feed
                        )
                    }
                },
                onSaveDish: { dish, section in
                    Task {
                        let went = await saveAction.toggle(
                            dishID: dish.dishID, entryID: nil, isSaved: dish.isSaved, source: .feed
                        )
                        if went, dish.isSaved == false { services.analytics(FeedEvents.dishSaved(section)) }
                    }
                },
                onViewed: { services.analytics(SocialEvents.feedViewed()) }
            )
        case .search:
            SearchScreen(store: search, saves: saveAction, open: { open($0, from: $1) })
        case .you:
            YouScreen(
                store: you,
                onRatings: { open(.ratings(score: $0)) },
                onDish: { open(.dish($0)) },
                onStatement: { open(.statement($0)) },
                onSettings: { open(.settings(.root)) },
                onViewed: { services.analytics(YouEvents.youViewed()) }
            )
        }
    }

    /// A hand-written binding because a tab bar's most-used gesture — tapping the tab you are already
    /// on — changes nothing and so never reaches `onChange`. The setter is where it can be heard.
    var selection: Binding<AteTab> {
        Binding(
            get: { tab },
            set: { tapped in
                guard tapped == tab else {
                    guard mayOpen(tapped) else { return }
                    tab = tapped
                    chrome.select(tapped) // the pill slides over; a tab is chosen on the full bar
                    // A tab is a place, not a layer: switching one leaves nothing pushed behind it.
                    path.removeAll()
                    return
                }
                scrollToTop[tab, default: 0] += 1
            }
        )
    }

    /// Pushes a destination — and refuses any that does not exist yet, so a link that has outrun
    /// its page does nothing at all rather than opening a blank one.
    ///
    /// `from` is remembered for the destination's view event. The funnel question is always "which
    /// entry point produced this", and an unlabelled one silently reads as zero.
    func open(_ route: Route, from source: DetailSource = .unknown) {
        guard route.isBuilt, mayOpen(route) else { return }
        sources[route] = source
        path.append(route)
    }

    func openComposer(_ origin: ComposerPresentation.Origin) {
        guard gate.permitsWrite(.compose) else { return }
        composing = ComposerPresentation(origin: origin)
    }

    /// Done in the composer: the entry is already on the journal, and this is the page it lands on.
    /// The stack is unwound first, so writing twice in a row does not stack entry pages.
    ///
    /// An *edit* lands on the same page it came from, so the path is left where it is — replacing it
    /// would push a second copy of the entry the person is already looking at.
    func landOnEntry(_ card: EntryCard) {
        journal.insert(card)
        tab = .journal
        guard path.contains(where: { $0.entryID == card.id }) == false else { return }
        path = [] // a new entry: the Summary's Done lands on the Journal, the entry at its top —
        scrollToTop[.journal, default: 0] += 1 // on screen, however far down the list was left
    }

    private func drainOutbox() async {
        let landed = await services.outbox.run()
        guard landed.isEmpty == false else { return }
        journal.invalidate()
        await journal.loadIfNeeded()
    }

    // MARK: - Session (the rest is in `AteShell+Session.swift`)

    /// The handle receipts are signed with — and, if it is still the one the server made up, the
    /// person is sent to `Handle` (a first run finished nowhere, or killed before it was noted).
    private func loadHandle() async {
        guard hasSession, handle == nil else { return }
        handle = await services.entries.currentHandle()
        if let handle, HandleName.isPlaceholder(handle), let userID = services.api.currentUserID {
            services.preferences.noteOwesHandle(userID)
        }
    }
}

/// The one screen that exists so a broken checkout says what is missing instead of crashing.
struct ConfigurationErrorView: View {
    let error: any Error

    var body: some View {
        LegacyEmptyState(
            title: "Nothing\nto talk to.",
            detail: String(describing: error)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateGround()
    }
}

#if DEBUG
#Preview("Staging") {
    AteRootView(environment: .success(AteEnvironment(
        name: .staging,
        supabaseURL: URL(string: "https://cvoitgoaosofkougmarn.supabase.co")!,
        supabaseKey: "sb_publishable_preview"
    )))
}

#Preview("Misconfigured") {
    AteRootView(environment: .failure(AteEnvironment.ConfigurationError.missing(key: "SUPABASE_URL")))
}
#endif
