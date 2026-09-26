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
        content
            // Settings' Appearance, applied to the window so Welcome, every sheet and every cover
            // follow it too — not just the views under one modifier.
            .ateAppearance(AtePreferences.standard.appearance)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG || BETA
        // The gallery has no backend at all, so it must not be reachable only through a screen that
        // needs one: `-ate-design-gallery` opens it straight from launch, which is also how it gets
        // driven on a simulator. Otherwise it presents from the ROOT (a `fullScreenCover` hung off a
        // menu's content is not a reliable presentation context).
        if ProcessInfo.processInfo.arguments.contains("-ate-design-gallery") {
            DesignSystemGallery()
        } else {
            resolved.designSystemGalleryPresenter()
        }
        #else
        resolved
        #endif
    }

    @ViewBuilder
    private var resolved: some View {
        switch environment {
        case .success:
            if let services {
                AteShell(services: services, onSessionEnded: { generation += 1 })
                    .id(generation)
            }
        case .failure(let error):
            ConfigurationErrorView(error: error)
        }
    }
}

/// **The shell**: the four tabs, the floating bar, the `+` that presents the composer, and the one
/// navigation stack the core loop travels on.
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
    @State var feedArea: FeedAreaModel // the feed's area, remembered per person
    @State private var saved: SavedDishesStore
    /// The one save, made once and handed down — it holds which dishes are mid-flight.
    @State private var saveAction: SaveAction
    /// Non-nil presents the composer, and carries what it was opened with.
    @State var composing: ComposerPresentation?
    /// The one stack every tab pushes onto. Hoisted here so Done in the composer can land on the new
    /// entry, at the journal's root, rather than under whatever was open before.
    @State var path: [Route] = []
    /// Where each pushed destination was opened from — the `source` its view event carries.
    ///
    /// Kept beside the path rather than inside ``Route``: a route is an *identity*, and two pushes of
    /// one place from two screens must stay equal to `NavigationStack` and `path.contains`.
    @State private var sources: [Route: DetailSource] = [:]
    /// How many recent photos are waiting to be written up — the journal header's badge. Only ever
    /// non-zero when the photo library has already been allowed; nothing here asks.
    @State var photoCount = 0
    /// Bumped when a tab's own item is tapped again — the screen scrolls to the top.
    @State private var scrollToTop = 0
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
    /// `-ate-open-summary`: the Summary a drive photographs without a composer to type into.
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
        if ComposerDebugLaunch.opensWelcome { hasSession = false }
        #endif
        _hasSession = State(initialValue: hasSession)
        _journal = State(initialValue: JournalStore(entries: services.entries, deletions: services.entryDeletions))
        let analytics = services.analytics
        let (feedStore, areaModel) = FeedScreen.stores(services: services)
        _feedArea = State(initialValue: areaModel)
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
        if SearchDebugLaunch.opensSearch {
            _tab = State(initialValue: .search)
            searchScope = SearchDebugLaunch.scope
            searchQuery = SearchDebugLaunch.query
        }
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
        if ComposerDebugLaunch.opensComposer {
            _composing = State(initialValue: ComposerPresentation(origin: .tabBar))
        }
        #endif
    }

    var body: some View {
        Group {
            if hasSession && owesHandle {
                firstRunHandle
            } else if hasSession || gate.isBrowsing {
                shell
                    .task(id: hasSession) { await loadHandle() }
            } else {
                welcome(isPrompt: false)
            }
        }
        // "The first write asks for sign-in": Welcome again, over the feed, with its link as Not Now.
        .fullScreenCover(isPresented: $gate.isAsking) { welcome(isPrompt: true) }
        .environment(gate)
        .task { await autoSignInIfRequested() }
        #if DEBUG
        .task { await openDebugScreenIfRequested() }
        .task { await openYouIfRequested() }
        .task { await openSettingsIfRequested() }
        #endif
        // An entry that could not be sent is still the person's. The outbox is worked on every
        // return to the app, and anything that lands refreshes the journal under it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await drainOutbox() }
        }
    }

    var shell: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                current
                AteTabScrim()
                // Above the scrim, or the fade washes the pill out. Only the shelf's own unsave
                // offers one (`SaveAction`), and it lives four seconds.
                if tab == .journal {
                    SavedUndoPill(store: saved) { Task { await saveAction.undoUnsaveFromShelf() } }
                }
                AteTabBar(selection: selection, onCompose: { openComposer(.tabBar) })
            }
            .ignoresSafeArea(.keyboard)
            .ateGround()
            .toolbar(.hidden, for: .navigationBar)
            .ateSwipeBack()
            .navigationDestination(for: Route.self) { route in
                destination(route)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .atePhotoViewerHost() // one full-screen viewer for every photo under the shell
        .fullScreenCover(item: $composing) { presentation in
            ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
        }
        #if DEBUG
        .fullScreenCover(item: $debugSummary) { summary in debugSummaryScreen(summary) }
        #endif
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .entry(let entry):
            EntryScreen(
                route: entry,
                services: services,
                saves: saveAction,
                onChange: { card in
                    journal.replace(card)
                    feed.replace(card)
                },
                onEdit: { composing = .edit($0) },
                onProfile: { open(.profile($0)) },
                onPlace: { open(.place($0), from: .entry) },
                onDish: { open(.dish($0), from: .entry) },
                onBlocked: {
                    // The person is gone from every read the server serves; the lists on this
                    // device catch up now rather than on the next launch.
                    path.removeAll()
                    Task { await feed.refresh() }
                }
            )
        case .profile(let userID):
            ProfileDestination(
                userID: userID,
                services: services,
                saves: saveAction,
                onOpen: { open(.entry(EntryRoute(entryID: $0.id))) },
                onPlace: { open(.place($0), from: .profile) },
                onDish: { open(.dish($0), from: .profile) },
                onBlocked: { blocked in
                    path.removeAll { $0 == .profile(blocked) }
                    Task { await feed.refresh() }
                }
            )
        case .place(let restaurantID):
            PlaceDestination(
                restaurantID: restaurantID,
                source: sources[route] ?? .unknown,
                services: services,
                saves: saveAction,
                onDish: { open(.dish($0), from: .place) },
                onOpen: { open(.entry(EntryRoute(entryID: $0.id))) },
                onProfile: { open(.profile($0)) }
            )
        case .dish(let dishID):
            DishDestination(
                dishID: dishID,
                source: sources[route] ?? .unknown,
                services: services,
                saves: saveAction,
                onPlace: { open(.place($0), from: .dish) },
                onEntry: { open(.entry(EntryRoute(entryID: $0))) }
            )
        case .ratings(let score):
            // `Ratings.dc.html` keeps the tab bar, exactly like `Suggestions`: it is a page of You,
            // not a modal.
            overTabBar {
                RatingsScreen(
                    score: score,
                    stats: services.stats,
                    onDish: { open(.dish($0)) },
                    onViewed: { services.analytics(YouEvents.ratingsViewed(score: $0)) }
                )
            }
        case .statement(let month):
            // `Recap.dc.html` draws no tab bar — a statement is a printout you hold, on its own.
            RecapScreen(
                month: month,
                stats: services.stats,
                // A receipt is signed. The You header is already loaded by the time a statement can
                // be opened, so its handle is the one on hand; the shell's is the fallback.
                handle: you.summary?.username ?? handle ?? "",
                analytics: services.analytics
            )
        case .settings(let page):
            settings(page)
        case .suggestions:
            // `Suggestions.dc.html` keeps the tab bar under it — it is a page of the journal, not a
            // modal. The stack's root bar is covered by the push, so the screen carries its own.
            overTabBar { suggestions }
        }
    }

    /// A pushed page that keeps the floating bar under it. The stack's root bar is covered by the
    /// push, so the page carries its own — and tapping a tab from one pops back to that tab.
    @ViewBuilder
    private func overTabBar(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack(alignment: .bottom) {
            content()
            AteTabScrim()
            AteTabBar(
                selection: Binding(get: { tab }, set: { tapped in
                    guard mayOpen(tapped) else { return }
                    tab = tapped
                    path.removeAll()
                }),
                onCompose: { openComposer(.tabBar) }
            )
        }
        .ateGround()
    }

    @ViewBuilder
    private var current: some View {
        switch tab {
        case .journal:
            JournalScreen(
                store: journal,
                saved: saved,
                scrollToTopSignal: scrollToTop,
                photoCount: photoCount,
                onCompose: { openComposer(.journalEmpty) },
                onOpen: { open(.entry(EntryRoute(entryID: $0.id))) },
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
            #if DEBUG
            .task { await openNewestEntryIfRequested() }
            .task { await openSummaryIfRequested() }
            .task {
                guard ComposerDebugLaunch.opensSuggestions, path.isEmpty else { return }
                path = [.suggestions]
            }
            #endif
        case .feed:
            FeedScreen(
                store: feed,
                area: feedArea,
                scrollToTopSignal: scrollToTop,
                onOpen: { open(.entry(EntryRoute(entryID: $0.id))) },
                onProfile: { open(.profile($0)) },
                onPlace: { open(.place($0), from: .feed) },
                onDish: { open(.dish($0), from: .feed) },
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
    private var selection: Binding<AteTab> {
        Binding(
            get: { tab },
            set: { tapped in
                guard tapped == tab else {
                    guard mayOpen(tapped) else { return }
                    tab = tapped
                    // A tab is a place, not a layer: switching one leaves nothing pushed behind it.
                    path.removeAll()
                    return
                }
                scrollToTop += 1
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

    private func openComposer(_ origin: ComposerPresentation.Origin) {
        guard gate.permitsWrite(.compose) else { return }
        composing = ComposerPresentation(origin: origin)
    }

    /// Done in the composer: the entry is already on the journal, and this is the page it lands on.
    /// The stack is unwound first, so writing twice in a row does not stack entry pages.
    ///
    /// An *edit* lands on the same page it came from, so the path is left where it is — replacing it
    /// would push a second copy of the entry the person is already looking at.
    private func landOnEntry(_ card: EntryCard) {
        journal.insert(card)
        tab = .journal
        guard path.contains(where: { $0.entryID == card.id }) == false else { return }
        path = [.entry(EntryRoute(entryID: card.id))]
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
        AteEmptyState(
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
