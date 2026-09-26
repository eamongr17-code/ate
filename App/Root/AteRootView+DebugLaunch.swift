import SwiftUI
import AteKit

#if DEBUG
/// What `-ate-open-summary` presents.
struct DebugSummary: Identifiable {
    let card: EntryCard
    let isPrinting: Bool
    var id: UUID { card.id }
}

/// The launch-argument drives: screens a simulator drive photographs, reachable from `simctl launch`
/// because a simulator cannot be tapped from a shell. Debug only, and out of the view's own file so
/// the shell stays readable — nothing here runs in a shipped build.
extension AteShell {
    /// `-ate-open-entry`: pushes the newest entry once the first page has landed. Waits for it
    /// rather than racing the journal's own load, which would find an empty list and give up.
    func openNewestEntryIfRequested() async {
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

    /// `-ate-open-summary` (`-ate-summary-printing` for the loading state): the Summary that follows
    /// Done, over the journal, on the design's own visit — the composer cannot be typed into from a
    /// shell, so the screen after it is reached directly.
    func openSummaryIfRequested() async {
        guard ComposerDebugLaunch.opensSummary, debugSummary == nil else { return }
        for _ in 0..<30 {
            await journal.loadIfNeeded()
            if let card = journal.entries.first(where: { $0.photos.count > 1 }) {
                debugSummary = DebugSummary(card: card, isPrinting: ComposerDebugLaunch.summaryPrints)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func debugSummaryScreen(_ summary: DebugSummary) -> some View {
        let entries = services.entries
        // Printing: the lines have not arrived, and a watch that never sees them arrive holds the
        // skeleton on screen long enough to be photographed.
        var start = summary.isPrinting ? summary.card.replacing(sortStatus: .pending, items: []) : summary.card
        if ComposerDebugLaunch.summaryHasNoPlace {
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

    /// `-ate-open-you` / `-ate-open-ratings` / `-ate-open-recap`: the You branch a drive
    /// photographs. It waits for the store rather than racing it — the bar a ratings page opens on
    /// and the month a statement prints both come out of the same first load.
    func openYouIfRequested() async {
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
            if ComposerDebugLaunch.opensRatings, let score = you.histogram.highestScore {
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

    /// `-ate-open-feed` / `-ate-open-profile` / `-ate-open-place` / `-ate-open-dish`: the screens a
    /// drive photographs, reachable from `simctl launch` because a simulator cannot be tapped from
    /// a shell. Each waits for the feed's first page rather than racing it, which would find an
    /// empty list and give up.
    func openDebugScreenIfRequested() async {
        guard ComposerDebugLaunch.opensFeed else { return }
        tab = .feed
        guard let route = await firstDebugRoute() else { return }
        open(route, from: .feed)
    }

    func firstDebugRoute() async -> Route? {
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
}
#endif

#if DEBUG
extension AteShell {
    /// `-ate-open-settings` / `-ate-open-handle` / `-ate-open-appearance` / `-ate-open-ai` /
    /// `-ate-open-blocked`: the settings branch a drive photographs, pushed from You the way a tap
    /// on the gear pushes it.
    func openSettingsIfRequested() async {
        guard let page = SettingsDebugLaunch.page, path.isEmpty else { return }
        for _ in 0..<40 where services.hasSession == false {
            try? await Task.sleep(for: .milliseconds(150))
        }
        tab = .you
        switch page {
        case .root:
            path = [.settings(.root)]
        case .handle:
            let current = try? await services.account.account().username
            path = [.settings(.root), .settings(.handle(current: current))]
        default:
            path = [.settings(.root), .settings(page)]
        }
    }
}
#endif
