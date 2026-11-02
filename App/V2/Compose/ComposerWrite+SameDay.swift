import AteKit
import SwiftUI

/// **One place, one day, one entry** (0103, `same-day-one-entry.html` section 3). Done on a new entry
/// first asks whether the person already posted this place that day. If they did, nothing new is
/// inserted: the post becomes an edit of that entry in their own hand (``SameDayMerge``) — their
/// earlier words, a blank line, the new words; the earlier photos then the new ones; everyone tagged on
/// either — and the receipt that prints is the whole day. Offline, or with no answer in a few seconds,
/// the post goes in as its own entry, exactly as before.
extension V2ComposerWrite {
    /// How long Done waits to hear about an earlier entry before posting a new one.
    static let sameDayPatience: Duration = .seconds(3)

    /// The earlier entry to add to, or `nil` to post as before. Remembered once found, so "Try again"
    /// adds to the same snapshot.
    func sameDayEntry(for request: NewEntryRequest) async -> EntryCard? {
        if let sameDayTarget { return sameDayTarget }
        guard model.editing == nil, let place = request.restaurantID else { return nil }
        let entries = services.entries
        let at = request.createdAt
        let patience = Self.sameDayPatience
        let found = await withTaskGroup(of: EntryCard?.self) { group -> EntryCard? in
            group.addTask { try? await entries.sameDayEntry(restaurantID: place, at: at) }
            group.addTask {
                try? await Task.sleep(for: patience)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // Only a printed entry is added to: one still sorting is left to finish as it is.
        guard let found, found.sortStatus == .sorted else { return nil }
        sameDayTarget = found
        return found
    }

    /// Saves the post into `earlier` and turns the sheet to its receipt, printing the whole day.
    func addToSameDay(_ earlier: EntryCard, request: NewEntryRequest, startedAt: ContinuousClock.Instant) {
        let base = EntryBodyTokens.composition(for: earlier)
        let items = earlier.items
        let merged = SameDayMerge.composition(base, adding: model.composition)
        let photos = SameDayMerge.photos(earlier.photos, adding: model.editedPhotos)
        let edit = EntryEdit(
            entryID: earlier.id,
            body: merged.plain,
            originalRestaurantID: earlier.restaurantID,
            restaurantID: earlier.restaurantID,
            tagTokens: merged.tagTokens,
            // As an edit does: only when every rated line came back as a pill.
            scoreTokens: ResortTokens.scoreTokens(of: base, rebuiltFrom: items) == nil ? nil : merged.scoreTokens,
            originalPhotos: earlier.photos,
            photos: photos,
            tags: EditTagDiff(original: base, current: merged, items: items, dietRemovals: [:]),
            originalBody: base.plain,
            originalEatenAt: earlier.createdAt,
            eatenAt: nil
        )
        if model.hasPendingPhotos {
            model.handOffLatePhotos(to: NewEntryRequest(
                id: earlier.id, body: edit.body, restaurantID: earlier.restaurantID,
                photoPaths: photos.map { _ in "" }, createdAt: earlier.createdAt, scoreCount: 0, secondsFromOpen: 0
            ))
        }
        let staged = services.outbox.staged
        let entries = services.entries
        let outbox = services.outbox
        let analytics = services.analytics
        let sync = services.companionTags
        let before = earlier.companions.map(\.userID)
        let after = SameDayMerge.people(before, adding: model.companions.map(\.userID))
        let shownPhotos = earlier.photos.sorted { $0.position < $1.position }.map { AtePhoto.remote($0.url) }
            + model.photos.filter { $0.remoteURL == nil }.map(\.photo)
        Task {
            do {
                let card = try await edit.save(to: entries, staged: staged)
                isSaving = false
                sameDayTarget = nil
                AteHaptics.success()
                AteTips.entryPosted()
                analytics(EntryEvents.addedToSameDay(
                    newScores: model.composition.scores.count, newPhotos: max(0, photos.count - earlier.photos.count)
                ))
                model.clearDraft()
                model.markEntrySaved()
                if let id = model.fulfilsOwnSave {
                    let own = app.ownSaves
                    Task { await own.fulfil(id: id) }
                }
                sendLatePhotos()
                if after != before {
                    Task.detached { _ = await sync.apply(entryID: card.id, from: before, to: after) }
                }
                // The new words put the entry back to printing (0097): the receipt feeds in now and its
                // lines print when the re-sort lands — the whole day, old lines and new.
                let sorted = Latch<EntryCard?>()
                let matched = Latch<Bool>()
                Task.detached {
                    let resorted = await edit.sort(
                        on: entries, owing: outbox, authorID: card.authorID, createdAt: card.createdAt
                    )
                    await sorted.fulfil(resorted)
                    await edit.matchPhotos(on: entries)
                    await matched.fulfil(true)
                    if let fresh = try? await entries.entry(id: edit.entryID) {
                        await MainActor.run { NotificationCenter.ateEntryChanged(fresh) }
                    }
                }
                var printed = V2ComposerPrinted.Handoff(
                    card: card,
                    photos: shownPhotos,
                    companions: model.companions.map(\.handle),
                    sorted: sorted,
                    tagTokens: merged.tagTokens,
                    scoreTokens: edit.scoreTokens,
                    doneAt: startedAt
                )
                printed.matched = matched
                onPrinted(printed)
            } catch {
                // Nothing is lost: the composer stays open, and "Try again" adds to the same snapshot.
                isSaving = false
                saveFailed = true
                isHandingOver = false
                model.cancelLateHandoff()
                model.focusEditor()
                analytics(EntryEvents.saveFailed(
                    isEdit: false, reason: EntryWriteFailure.of(error).isRetryable ? "offline" : "rejected"
                ))
            }
        }
    }
}
