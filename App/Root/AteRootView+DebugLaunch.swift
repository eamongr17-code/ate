import SwiftUI
import AteKit

#if DEBUG
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
