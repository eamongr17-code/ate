import AteKit
import SwiftUI

/// **A latest receipt's actions** — the one actions sheet (Save this place, Share, Report, Block
/// @handle), pointed at this visit and its author, as the entry page's is. Save this place saves
/// every dish on the visit; Share hands over a link to it, never their receipt (round 5); a block
/// takes the author off the Feed.
struct FeedSlipActionsSheet: View {
    /// The slip as it was long-pressed.
    let pressed: EntryCard
    /// Where the live row is read from, so Save flips in place as the save lands.
    let latest: EntryListStore
    let app: AppModel
    let onBlocked: (UUID) -> Void

    private var entry: EntryCard { latest.entry(id: pressed.id) ?? pressed }

    var body: some View {
        let entry = entry
        let handle = entry.author.map { "@\($0.username)" } ?? "This entry"
        AteActionsSheet(
            title: handle,
            blockTitle: "Block \(handle)",
            onSave: entry.items.isEmpty ? nil : savePlace,
            isSaved: entry.isEveryDishSaved,
            onShare: { EntryLinkShare.items(for: entry, handle: entry.author?.username) },
            onReport: report,
            onBlock: block
        )
    }

    private func savePlace() {
        let saves = app.saves
        let entry = entry
        let dishIDs = entry.items.map(\.dishID)
        Task {
            if entry.isEveryDishSaved {
                await saves.unsaveEveryDish(dishIDs: dishIDs, source: .feed)
            } else {
                _ = await saves.saveEveryDish(entryID: entry.id, dishIDs: dishIDs, source: .feed)
            }
        }
    }

    private func report() {
        let services = app.services
        let entryID = entry.id
        Task {
            guard (try? await services.profiles.report(entryID: entryID, reason: nil, note: nil)) != nil else { return }
            services.analytics(SocialEvents.entryReported())
        }
    }

    private func block() {
        let services = app.services
        let authorID = entry.authorID
        Task {
            guard (try? await services.profiles.block(userID: authorID)) != nil else { return }
            services.analytics(SocialEvents.userBlocked())
            onBlocked(authorID)
        }
    }
}
