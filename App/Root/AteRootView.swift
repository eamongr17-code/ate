import AteKit
import SwiftUI

/// **The app's root.** Resolves the build's environment into either the shell or a loud, readable
/// configuration error — a misconfigured checkout must explain itself, not crash.
struct AteRootView: View {
    let environment: Result<AteEnvironment, Error>

    var body: some View {
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
        case .success(let environment):
            AteShell(services: AteServices(environment: environment))
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
private struct AteShell: View {
    let services: AteServices

    @State private var tab: AteTab = .journal
    @State private var journal: JournalStore
    /// Everyone else's entries, and the shelf a save fills. Held here rather than by the screens so
    /// a save made in the feed is already true on the shelf, and a block empties both at once.
    @State private var feed: EntryListStore
    @State private var saved: SavedDishesStore
    /// The one save, made once and handed down — it holds which dishes are mid-flight.
    @State private var saveAction: SaveAction
    /// Non-nil presents the composer, and carries what it was opened with.
    @State private var composing: ComposerPresentation?
    /// The one stack every tab pushes onto. Hoisted here so Done in the composer can land on the new
    /// entry, at the journal's root, rather than under whatever was open before.
    @State private var path: [Route] = []
    /// Where each pushed destination was opened from — the `source` its view event carries.
    ///
    /// Kept beside the path rather than inside ``Route`` on purpose: a route is an *identity*, and
    /// two pushes of the same place from two different screens must still be the same value to
    /// `NavigationStack` (and to `path.contains`). Folding the source into the case would make them
    /// different routes and quietly break every comparison on the path.
    @State private var sources: [Route: DetailSource] = [:]
    /// How many recent photos are waiting to be written up — the journal header's badge. Only ever
    /// non-zero when the photo library has already been allowed; nothing here asks.
    @State private var photoCount = 0
    /// Bumped when a tab's own item is tapped again — the screen scrolls to the top.
    @State private var scrollToTop = 0
    @State private var hasSession: Bool
    @State private var isSigningIn = false
    /// The signed-in person's handle. A receipt is signed, so it is loaded once at the shell rather
    /// than by whichever screen happens to need it first.
    @State private var handle: String?
    /// The You tab, held here rather than by the screen so switching away and back does not re-read
    /// five RPCs — and so a pull-to-refresh on it is the only thing that does.
    @State private var you: YouStore
    @Environment(\.scenePhase) private var scenePhase

    init(services: AteServices) {
        self.services = services
        var hasSession = services.hasSession
        #if DEBUG
        if ComposerDebugLaunch.opensWelcome { hasSession = false }
        #endif
        _hasSession = State(initialValue: hasSession)
        _journal = State(initialValue: JournalStore(entries: services.entries))
        let feedReader = services.feed
        let analytics = services.analytics
        let feedStore = EntryListStore(
            fallbackMessage: "Couldn't load the feed.",
            savedDishes: services.savedDishes
        ) { cursor, pageSize in
            try await feedReader.feedPage(after: cursor, pageSize: pageSize, includeOwn: false)
        }
        // `feed_page_loaded` is reported where the page actually lands — a prefetched page and a
        // pulled one count the same, and a refresh cannot swallow its own first page by resetting
        // the count and filling it again in the same turn.
        feedStore.onPageLoaded = { page, items in
            analytics(SocialEvents.feedPageLoaded(page: page, itemCount: items))
        }
        _feed = State(initialValue: feedStore)
        _you = State(initialValue: YouStore(stats: services.stats))
        let shelf = SavedDishesStore(saves: services.saves)
        _saved = State(initialValue: shelf)
        _saveAction = State(initialValue: SaveAction(
            saves: services.saves,
            analytics: services.analytics,
            shelf: shelf,
            broadcast: services.savedDishes
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
            if hasSession {
                shell
                    .task(id: hasSession) { await loadHandle() }
            } else {
                WelcomeScreen(
                    canSignIn: services.debugSignIn != nil,
                    isBusy: isSigningIn,
                    onSignIn: signIn
                )
            }
        }
        .task { await autoSignInIfRequested() }
        #if DEBUG
        .task { await openDebugScreenIfRequested() }
        .task { await openYouIfRequested() }
        #endif
        // An entry that could not be sent is still the person's. The outbox is worked on every
        // return to the app, and anything that lands refreshes the journal under it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await drainOutbox() }
        }
    }

    private var shell: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                current
                AteTabScrim()
                AteTabBar(selection: selection, onCompose: { openComposer(.tabBar) })
            }
            .ignoresSafeArea(.keyboard)
            .ateGround()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                destination(route)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .fullScreenCover(item: $composing) { presentation in
            ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
        }
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
        case .suggestions:
            // `Suggestions.dc.html` keeps the tab bar under it — it is a page of the journal, not a
            // modal. The stack's root bar is covered by the push, so the screen carries its own.
            overTabBar {
                SuggestionsScreen(library: services.photos) { cluster in
                    composing = ComposerPresentation(
                        origin: .photoSuggestion,
                        assetIdentifiers: cluster.items.map(\.id)
                    )
                }
            }
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
            .task {
                guard ComposerDebugLaunch.opensSuggestions, path.isEmpty else { return }
                path = [.suggestions]
            }
            #endif
        case .feed:
            FeedScreen(
                store: feed,
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
            SearchScreen()
        case .you:
            YouScreen(
                store: you,
                onRatings: { open(.ratings(score: $0)) },
                onDish: { open(.dish($0)) },
                onStatement: { open(.statement($0)) },
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
    private func open(_ route: Route, from source: DetailSource = .unknown) {
        guard route.isBuilt else { return }
        sources[route] = source
        path.append(route)
    }

    private func openComposer(_ origin: ComposerPresentation.Origin) {
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

    /// The header badge. Reads the camera roll only when it has already been allowed — the ask
    /// belongs to `Suggestions`, and a launch that asks for photos is exactly what the design's
    /// "nothing is ever assumed" rule is against.
    private func countPhotos() async {
        guard services.photos.isAuthorized else { return }
        photoCount = PhotoSuggestions.cluster(await services.photos.recent())
            .reduce(0) { $0 + $1.items.count }
    }

    #if DEBUG
    /// `-ate-open-entry`: pushes the newest entry once the first page has landed. Waits for it
    /// rather than racing the journal's own load, which would find an empty list and give up.
    private func openNewestEntryIfRequested() async {
        guard ComposerDebugLaunch.opensEntry, path.isEmpty else { return }
        for _ in 0..<30 {
            await journal.loadIfNeeded()
            // `Share` is photographed for its photo cluster, so that drive wants an entry that has
            // one. Everything else takes the newest, whatever it carries.
            let wanted = ComposerDebugLaunch.opensShare
                ? journal.entries.first { $0.photos.count > 1 } ?? journal.entries.first
                : journal.entries.first
            if let wanted {
                path = [.entry(EntryRoute(entryID: wanted.id))]
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif

    #if DEBUG
    /// `-ate-open-you` / `-ate-open-ratings` / `-ate-open-recap`: the You branch a drive
    /// photographs. It waits for the store rather than racing it — the bar a ratings page opens on
    /// and the month a statement prints both come out of the same first load.
    private func openYouIfRequested() async {
        guard ComposerDebugLaunch.opensYou, path.isEmpty else { return }
        tab = .you
        for _ in 0..<40 {
            // The debug sign-in is still in flight on the first turns. Read the client rather
            // than this view's own `hasSession`, which is a snapshot taken when the task started.
            guard services.hasSession else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            await you.loadIfNeeded()
            if ComposerDebugLaunch.opensRatings, let score = you.histogram.busiestScore {
                path = [.ratings(score: score)]
                return
            }
            if ComposerDebugLaunch.opensRecap, let month = you.month {
                path = [.statement(month)]
                return
            }
            if ComposerDebugLaunch.opensRatings || ComposerDebugLaunch.opensRecap {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            return
        }
    }
    #endif

    #if DEBUG
    /// `-ate-open-feed` / `-ate-open-profile` / `-ate-open-place` / `-ate-open-dish`: the screens a
    /// drive photographs, reachable from `simctl launch` because a simulator cannot be tapped from
    /// a shell. Each waits for the feed's first page rather than racing it, which would find an
    /// empty list and give up.
    private func openDebugScreenIfRequested() async {
        guard ComposerDebugLaunch.opensFeed else { return }
        tab = .feed
        guard let route = await firstDebugRoute() else { return }
        open(route, from: .feed)
    }

    private func firstDebugRoute() async -> Route? {
        let wantsProfile = ComposerDebugLaunch.opensProfile
        let wantsPlace = ComposerDebugLaunch.opensPlace
        let wantsDish = ComposerDebugLaunch.opensDish
        guard wantsProfile || wantsPlace || wantsDish else { return nil }

        for _ in 0..<40 {
            await feed.loadIfNeeded()
            if wantsProfile, let first = feed.entries.first {
                return .profile(first.authorID)
            }
            if wantsPlace, let place = feed.entries.compactMap(\.place?.id).first {
                return .place(place)
            }
            if wantsDish, let dish = feed.entries.flatMap(\.items).map(\.dishID).first {
                return .dish(dish)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }
    #endif

    private func drainOutbox() async {
        let landed = await services.outbox.run()
        guard landed.isEmpty == false else { return }
        journal.invalidate()
        await journal.loadIfNeeded()
    }

    // MARK: - Session

    /// Sign in with Apple is milestone 2. Until then the one path in is the seeded staging demo
    /// account, which exists in Debug and Beta only (`DebugStagingSignIn`).
    private func signIn() async {
        guard let debugSignIn = services.debugSignIn else { return }
        isSigningIn = true
        await debugSignIn.signIn()
        isSigningIn = false
        hasSession = services.hasSession
        journal.invalidate()
    }

    private func autoSignInIfRequested() async {
        guard hasSession == false, let debugSignIn = services.debugSignIn,
              debugSignIn.isAutoSignInRequested else { return }
        await signIn()
    }

    private func loadHandle() async {
        guard hasSession, handle == nil else { return }
        handle = await services.entries.currentHandle()
    }
}

/// The one screen that exists so a broken checkout says what is missing instead of crashing.
struct ConfigurationErrorView: View {
    let error: any Error

    var body: some View {
        AteEmptySlip(
            label: "Configuration",
            title: "Nothing\nto talk to.",
            prose: String(describing: error)
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
