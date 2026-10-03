#if DEBUG
import AteKit
import SwiftUI

/// What `-ate-open summary/<id>` presents.
struct DebugSummary: Identifiable {
    let card: EntryCard
    let isPrinting: Bool
    var id: UUID { card.id }
}

/// **Where a drive's launch opens** (`-ate-open <route>`, ``DebugLaunch``), as the shell's own
/// starting state: a tab, a stack on it, a cover over it — set before the first frame, so a drive
/// lands on its screen without a tap and without waiting for a list to load first. Pages are pushed
/// on the tab a person reaches them from: an entry and `Suggestions` on the Journal; a profile,
/// place or dish on the Feed; ratings, a statement and Settings on You.
///
/// Debug only, and out of the shell's own file: nothing here runs in a shipped build.
struct DebugStart {
    private(set) var tab: AteTab = .journal
    private(set) var path: [Route] = []
    /// Where the pushed page says it was opened from.
    private(set) var sources: [Route: DetailSource] = [:]
    private(set) var composes = false
    /// `Welcome`, even with a session — the one screen you cannot reach once you are signed in.
    private(set) var showsWelcome = false

    // A flat table of screens; splitting it would only hide which tab each one lands on.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ route: LaunchRoute?) {
        guard let route else { return }
        switch route.screen {
        // The Journal's shelf and filters, Search's segment and words, the first-run handle and the
        // Summary are read by their own screens (`JournalDebugLaunch`, `SearchDebugLaunch`,
        // `SettingsDebugLaunch`, ``AteShell/finishDebugLaunch()``).
        case .journal, .saved, .firstRunHandle, .summary: break
        case .feed: tab = .feed
        case .search: tab = .search
        case .you: tab = .you
        case .composer: composes = true
        case .welcome: showsWelcome = true
        case .entry(let entryID): path = [.entry(EntryRoute(entryID: entryID))]
        case .suggestions: path = [.suggestions]
        case .profile(let userID): push(.profile(userID), on: .feed, from: .feed)
        case .place(let restaurantID): push(.place(restaurantID), on: .feed, from: .feed)
        case .dish(let dishID): push(.dish(dishID), on: .feed, from: .feed)
        case .ratings(let score): push(.ratings(score: score), on: .you)
        case .kit:
            // The gallery, pushed from Settings the way its row pushes it.
            tab = .you
            path = [.settings(.root), .settings(.kit)]
        case .statement(let month): push(.statement(month), on: .you)
        case .settings(let page):
            // Pushed from You the way a tap on the gear pushes it. The handle page waits for the
            // handle it opens on (``AteShell/finishDebugLaunch()``).
            tab = .you
            path = [.settings(.root)]
            if let page = page.flatMap(Self.settingsPage) { path.append(.settings(page)) }
        }
    }

    private mutating func push(_ route: Route, on tab: AteTab, from source: DetailSource = .unknown) {
        self.tab = tab
        path = [route]
        sources = [route: source]
    }

    private static func settingsPage(_ page: LaunchRoute.SettingsPage) -> SettingsPage? {
        switch page {
        case .handle: nil
        case .appearance: .appearance
        case .ai: .artificialIntelligence
        case .blocked: .blocked
        }
    }
}

extension AteShell {
    /// The two launches that need a read before their screen can be drawn — Settings' handle page,
    /// which opens on the current handle, and the Summary, which prints an entry. One read each,
    /// once there is a session to read with.
    func finishDebugLaunch() async {
        guard hasSession, let route = DebugLaunch.route else { return }
        switch route.screen {
        case .settings(.handle?):
            guard path == [.settings(.root)] else { return }
            let current = try? await services.account.account().username
            path.append(.settings(.handle(current: current)))
        case .summary(let entryID):
            guard debugSummary == nil, let card = try? await services.entries.entry(id: entryID) else { return }
            debugSummary = DebugSummary(card: card, isPrinting: route.has(.printing))
        default:
            return
        }
    }

    /// `-ate-open summary/<id>` (`?printing` for the loading state, `?no-place` for a receipt that
    /// waits on the Place key): the Summary that follows Done, over the journal — the composer
    /// cannot be typed into from a shell, so the screen after it is reached directly.
    func debugSummaryScreen(_ summary: DebugSummary) -> some View {
        let entries = services.entries
        // Printing: the lines have not arrived, and a watch that never sees them arrive holds the
        // skeleton on screen long enough to be photographed.
        var start = summary.isPrinting ? summary.card.replacing(sortStatus: .pending, items: []) : summary.card
        if DebugLaunch.has(.noPlace) {
            // Written with no place: sorted, plan parked, nothing to print until one is attached.
            let card = summary.card
            start = EntryCard(
                id: card.id, authorID: card.authorID, body: card.body, orderNumber: card.orderNumber,
                sortStatus: .sorted, sortedAt: card.sortedAt, createdAt: card.createdAt,
                author: card.author, photos: card.photos
            )
        }
        let shown = start
        return SummaryScreen(
            card: shown,
            photos: summary.card.photos.map { AtePhoto(url: URL(string: $0.url)) },
            handle: summary.card.author?.username ?? "",
            actions: summary.isPrinting
                ? EntrySummaryStore.Actions(
                    fetch: { _ in shown },
                    correctPlace: { _, _ in shown },
                    resort: { _ in }
                )
                : .live(entries, tagTokens: []),
            places: services.places,
            analytics: services.analytics,
            onDone: { debugSummary = nil }
        )
    }
}
#endif
