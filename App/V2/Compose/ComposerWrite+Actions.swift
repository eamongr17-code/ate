import AteKit
import AVFoundation
import PhotosUI
import SwiftUI

/// The composer's actions — the tick (a new entry or an edit), the early sort, photos and the camera
/// key — ported from the current composer (`ComposerScreen+Actions`) with the same rules, timings and
/// events. Split from ``V2ComposerWrite`` for length; the state is the view's own.
extension V2ComposerWrite {
    // MARK: - The tick

    /// The words go first and alone; the photos and the sorter follow at once, side by side. Nothing
    /// about the receipt may delay the writing being saved.
    ///
    /// The tick steps its dots only while the words are being saved (build 87, note 11: the wait
    /// was the slowest part of logging). The moment they are, the sheet turns to the printed face:
    /// the receipt's paper feeds in at once with skeleton lines, and the sorted lines print onto it
    /// in place when the sort's own reply lands — the receipt enters once, and never as an empty
    /// coral sheet. Offline, the entry is queued and the sheet simply closes: there is no order
    /// number to print yet.
    func post() {
        guard isSaving == false, model.canSave else { return }
        let startedAt = ContinuousClock.now
        isSaving = true
        saveFailed = false
        isHandingOver = true
        model.dismissScoring(refocus: false)
        model.promotePendingTagLiteral().map(services.analytics)
        // Done's last word to the early sort: the words exactly as they will be inserted. A preview
        // of them already out is left to land; a stale one gets one more, which the sort waits on.
        // Then nothing further goes.
        let input = model.earlySortInput
        let cacheHit = earlySort?.covers(input) ?? false
        earlySort?.now(input)
        earlySort?.stop()

        Task {
            // A pick still being written is part of the entry — but the tick waits on it only so
            // long. Past that the entry saves without it, and it follows the moment it lands.
            let photosReady = await BoundedWait.until(timeout: BoundedWait.pendingPhotos) {
                model.hasPendingPhotos == false
            }
            if photosReady == false {
                services.analytics(EntryEvents.photoLate(count: model.photos.filter(\.isPending).count))
            }
            if let editing = model.editing {
                rewrite(editing)
            } else {
                await submit(startedAt: startedAt, cacheHit: cacheHit)
            }
        }
    }

    private func submit(startedAt: ContinuousClock.Instant, cacheHit: Bool) async {
        let draft = model.draft
        let request = model.request(from: draft, photoDirectory: model.photoDirectory)
        if model.hasPendingPhotos { model.handOffLatePhotos(to: request) }
        let submission = services.submission
        let analytics = services.analytics

        // Photos and the sorter, side by side — started the moment the words land, not after the row
        // is read back, and detached from this view: closing the receipt must not cancel the rest of
        // the entry landing. The latch hears the sort.
        let sorted = Latch<EntryCard?>()
        let finish: @Sendable () -> Void = {
            Task.detached {
                let card = await submission.finish(
                    entryID: request.id,
                    photoPaths: request.photoPaths,
                    tagTokens: request.tagTokens,
                    scoreTokens: request.scoreTokens,
                    dietOffTokens: request.dietOffTokens,
                    sorted: { await sorted.fulfil($0) }
                )
                // Its photos are paired with its dishes by now (0063): an open page reads them again.
                guard let card, request.photoPaths.isEmpty == false else { return }
                await MainActor.run { NotificationCenter.ateEntryChanged(card) }
            }
        }
        let result = await submission.submit(request, onInserted: finish)
        guard let card = result.card else {
            isSaving = false
            model.cancelLateHandoff()
            giveBackTheKeyboard()
            if result.isPlaceRequired {
                // The server says there is no place: the Place key is empty again and the tick
                // waits on it — not a retry that cannot work.
                model.detachPlace()
                analytics(EntryEvents.saveFailed(isEdit: false, reason: "place_required"))
                return
            }
            // Refused. Everything stays exactly where it is, and the sheet asks to try again.
            saveFailed = true
            analytics(EntryEvents.saveFailed(isEdit: false, reason: "rejected"))
            return
        }
        AteHaptics.success()
        AteTips.entryPosted()
        if let source = model.date.source, model.date.daysAgo() > 0 {
            analytics(EntryEvents.dated(source: source, daysAgo: model.date.daysAgo()))
        }
        writeUpSuggestedPhotos()
        model.clearDraft()
        model.markEntrySaved()
        // "I ate it": the dish is in the Journal now, so it leaves Saved. Only once the entry has
        // landed: a queued one can still fail for good, and the dish must not vanish from both.
        if case .saved = result, let id = model.fulfilsOwnSave {
            let own = app.ownSaves
            Task { await own.fulfil(id: id) }
        }
        sendLatePhotos()
        // The people go behind the words, never in front of them: queued offline with the entry,
        // and sent once it has landed.
        sendCompanions(entryID: request.id, from: [])

        guard case .saved = result else {
            // Queued: the insert never landed (offline, or past its patience), so nothing has
            // started — try the rest now (the outbox has it either way). The printed face still
            // comes up, saying the entry is saved and the receipt finishes once there is a
            // connection (receipt fallback), rather than the sheet closing without a word.
            finish()
            NotificationCenter.ateEntryChanged(card)
            onPrinted(handoff(card, request: request, sorted: nil, doneAt: startedAt, cacheHit: cacheHit))
            return
        }

        // No hold: the printed face comes up now, its paper already feeding in. `post_held` still
        // says how long the tick held and whether the sort had landed by then.
        let landed = await sorted.value(before: .now)
        analytics(EntryEvents.postHeld(
            outcome: PostHold.outcome(landed),
            milliseconds: PostHold.milliseconds(since: startedAt)
        ))
        let shown = landed.flatMap { $0 } ?? card
        onPrinted(handoff(shown, request: request, sorted: sorted, doneAt: startedAt, cacheHit: cacheHit))
        // The lists under the sheet hear about it once the receipt is up, not competing with it.
        Task {
            try? await Task.sleep(for: V2ComposerTiming.landing)
            NotificationCenter.ateEntryChanged(shown)
        }
    }

    /// What the printed face is handed. No latch means the words went to the outbox (queued).
    private func handoff(
        _ card: EntryCard, request: NewEntryRequest, sorted: Latch<EntryCard?>?,
        doneAt: ContinuousClock.Instant, cacheHit: Bool
    ) -> V2ComposerPrinted.Handoff {
        V2ComposerPrinted.Handoff(
            card: card,
            photos: model.photos.map(\.photo),
            companions: model.companions.map(\.handle),
            sorted: sorted,
            tagTokens: request.tagTokens,
            scoreTokens: request.scoreTokens,
            dietOffTokens: request.dietOffTokens,
            doneAt: doneAt,
            cacheHit: cacheHit,
            isQueued: sorted == nil
        )
    }

    /// "Ate with": who was added and who was taken off, handed to the tag queue — detached, so
    /// closing the sheet never cancels it, and a failure never reaches the person (it retries, or is
    /// a refusal that will not change).
    private func sendCompanions(entryID: UUID, from original: [CompanionPerson]) {
        guard model.companionsChanged else { return }
        let before = original.map(\.userID)
        let after = model.companions.map(\.userID)
        let sync = services.companionTags
        let analytics = services.analytics
        Task.detached {
            let added = await sync.apply(entryID: entryID, from: before, to: after)
            if added > 0 { analytics(CompanionEvents.tagged(count: added)) }
        }
        // The one ask (push): the first time someone is tagged, never at launch.
        if Set(after).subtracting(before).isEmpty == false {
            let services = services
            Task { await AtePush.shared.askOnce(trigger: .tag, services: services) }
        }
    }

    /// A save that did not land: the composer is the writing surface again.
    private func giveBackTheKeyboard() {
        isHandingOver = false
        model.focusEditor()
    }

    /// Editing an entry that already exists: the body is rewritten in place, and the sorter is asked
    /// again **without forcing** — a forced re-sort would throw away dish corrections already made.
    /// A place picked on the key is attached with `correct_entry_place`; chips typed during the edit
    /// go to a forced re-sort as `tag_tokens`, with the entry's 6s beside them (``EntryEdit``).
    private func rewrite(_ editing: ComposerPresentation.EditingEntry) {
        let edit = EntryEdit(
            entryID: editing.id,
            body: model.composition.plain,
            originalRestaurantID: editing.restaurantID,
            restaurantID: model.place?.id,
            tagTokens: model.composition.tagTokens,
            // Only when every rated line came back as a pill: an older entry scored from prose would
            // otherwise lose that dish to the re-sort.
            scoreTokens: ResortTokens.scoreTokens(of: editing.composition, rebuiltFrom: editing.items) == nil
                ? nil : model.composition.scoreTokens,
            originalPhotos: editing.photos,
            photos: model.editedPhotos,
            tags: EditTagDiff(
                original: editing.composition, current: model.composition, items: editing.items,
                dietRemovals: model.diet.removals
            ),
            originalBody: editing.composition.plain,
            originalEatenAt: editing.createdAt,
            eatenAt: model.date.eatenAt
        )
        if model.hasPendingPhotos {
            model.handOffLatePhotos(to: NewEntryRequest(
                id: editing.id, body: edit.body, restaurantID: model.place?.id,
                photoPaths: model.editedPhotos.map { _ in "" }, createdAt: Date(), scoreCount: 0, secondsFromOpen: 0
            ))
        }
        let staged = services.outbox.staged
        let entries = services.entries
        let analytics = services.analytics
        Task {
            do {
                let card = try await edit.save(to: entries, staged: staged)
                isSaving = false
                writeUpSuggestedPhotos()
                model.markEntrySaved()
                sendLatePhotos()
                sendCompanions(entryID: editing.id, from: model.originalCompanions)
                if edit.changesPlace { analytics(EntryEvents.corrected(.place)) }
                if edit.changesDate { analytics(EntryEvents.corrected(.date)) }
                AteHaptics.success()
                NotificationCenter.ateEntryChanged(card)
                dismiss()
                // The re-sort lands after the sheet has gone: tell the entry page (and the lists)
                // again, so dishes added in the edit appear the moment they are printed.
                // Then the photos are paired with the dishes again (0063), without holding the lines.
                Task.detached {
                    if let sorted = await edit.sort(on: entries) {
                        await MainActor.run { NotificationCenter.ateEntryChanged(sorted) }
                    }
                    await edit.matchPhotos(on: entries)
                    if let card = try? await entries.entry(id: edit.entryID) {
                        await MainActor.run { NotificationCenter.ateEntryChanged(card) }
                    }
                }
            } catch {
                // A failed edit never closes the composer and never loses a change.
                isSaving = false
                saveFailed = true
                model.cancelLateHandoff()
                giveBackTheKeyboard()
                analytics(EntryEvents.saveFailed(
                    isEdit: true, reason: EntryWriteFailure.of(error).isRetryable ? "offline" : "rejected"
                ))
            }
        }
    }

    // MARK: - Photos

    /// The photos just posted are written up: their sittings leave From your photos and the
    /// Journal's count (``PhotoSuggestionDismissals``). A picked or suggested photo is known by its
    /// library id; one the entry already had, or a camera shot, matches nothing.
    private func writeUpSuggestedPhotos() {
        let ids = model.photos.filter { $0.remoteURL == nil }.map(\.id)
        guard ids.isEmpty == false else { return }
        PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: services.photoOwner).writeUp(ids)
        NotificationCenter.default.post(name: .ateSuggestionPhotosWrittenUp, object: nil)
    }

    /// A composer opened from a photo suggestion arrives holding a cluster's photos: staged the same
    /// way the picker's are, and bringing nothing with them but their pixels — never a place.
    func stageSuggestedPhotos() async {
        guard presentation.assetIdentifiers.isEmpty == false, model.photos.isEmpty else { return }
        var images: [(id: String, image: UIImage)] = []
        for identifier in presentation.assetIdentifiers {
            guard let image = await services.photos.image(
                id: identifier, maximumDimension: ComposerPhotoStaging.maximumDimension
            ) else { continue }
            images.append((id: identifier, image: image))
        }
        let staged = await ComposerPhotoStaging.stage(images: images, in: model.photoDirectory, existing: [])
        // Anything picked while they were written stays, after them.
        let added = model.photos.filter { photo in staged.contains { $0.id == photo.id } == false }
        model.setPhotos(Array((staged + added).prefix(EntryDraft.photoLimit)))
        // The suggestion's photos bring their own day (date-and-photos.html).
        model.photosDated(services.photos.takenAt(ids: images.map(\.id)))
    }

    /// **Library picks appear at once**: a still tile the moment the picker closes, its preview as
    /// soon as there is one, the bytes written behind it.
    func stage(_ items: [PhotosPickerItem]) {
        guard isFrozen == false else {
            pickedItems = []
            return
        }
        let keyed = items.map { (id: ComposerPhotoStaging.key(for: $0), item: $0) }
        let accepted = Set(model.beginPhotos(ids: keyed.map(\.id)))
        pickedItems = []
        let directory = model.photoDirectory
        for (id, item) in keyed where accepted.contains(id) {
            if services.photos.isAuthorized, let identifier = item.itemIdentifier {
                Task {
                    if let quick = await services.photos.thumbnail(
                        id: identifier, side: AteMetrics.clusterPhotoComposer
                    ) {
                        model.previewPhoto(id: id, image: quick)
                    }
                }
            }
            Task {
                let staged = await ComposerPhotoStaging.stage(item, in: directory) { preview in
                    model.previewPhoto(id: id, image: preview)
                }
                guard let staged else {
                    // Unreadable: the tile goes, the refusal is felt and counted.
                    model.dropPhoto(id: id)
                    AteHaptics.refused()
                    services.analytics(EntryEvents.photoFailed(stage: "pick"))
                    return
                }
                model.finishPhoto(id: id, fileName: staged.fileName, image: staged.image)
                // The day it was taken: the file's own EXIF, else the library's record of it.
                model.photosDated([
                    staged.takenAt ?? item.itemIdentifier.flatMap { services.photos.takenAt(ids: [$0]).first }
                ])
                if model.lateHandoff != nil {
                    model.landLate(fileName: staged.fileName)
                    sendLatePhotos()
                }
            }
        }
    }

    /// Late picks up to the saved entry: straight away if they can, otherwise through the outbox.
    func sendLatePhotos() {
        guard let late = model.takeLatePhotos() else { return }
        let submission = services.submission
        let outbox = services.outbox
        Task.detached {
            var queued = false
            for photo in late.photos {
                let landed = await submission.attachLate(late.request, path: photo.path, position: photo.position)
                queued = queued || landed == false
            }
            if queued { await outbox.run() }
        }
    }

    /// Files a day old that nothing references go; young files never do.
    func sweepStagedPhotos() async {
        guard let root = services.drafts.draftPhotosRoot else { return }
        var keep = await services.outbox.staged.recordedPaths
        keep.formUnion(await services.outbox.pendingPhotoPaths)
        let directory = model.photoDirectory
        keep.formUnion(model.photos.compactMap(\.fileName).map { directory.appending(path: $0).path() })
        keep.formUnion(services.drafts.draftReferencedPhotoPaths)
        let referenced = keep
        await Task.detached(priority: .utility) { StagedFiles.sweep(root, keeping: referenced) }.value
    }

    /// `sort-entry` `{health: true}` as the composer opens, so Done does not pay a cold start. Fire
    /// and forget: never waited on, never an error.
    func warmUpSorter() {
        let entries = services.entries
        Task.detached(priority: .utility) { await entries.warmUp() }
    }

    /// The words changed. While typing, the early sort waits for a pause; a place attached or
    /// changed, or a diet chip added, is a settled moment and goes at once.
    func earlySortEdited(from old: EarlySortInput?, to new: EarlySortInput?) {
        let placeChanged = old?.restaurantID != new?.restaurantID
        let tagAdded = (new?.tagTokens.count ?? 0) > (old?.tagTokens.count ?? 0)
        if new != nil, placeChanged || tagAdded {
            earlySort?.now(new)
        } else {
            earlySort?.edited(new)
        }
    }

    /// A settled moment with no edit in it — the score slide closed, the keyboard went down.
    func earlySortSettled() {
        guard isSaving == false else { return }
        earlySort?.now(model.earlySortInput)
    }

    /// The early sort, wired to the entry service and counted. Never for an edit.
    func startEarlySort() {
        guard earlySort == nil, model.editing == nil else { return }
        let entries = services.entries
        let analytics = services.analytics
        let scheduler = EarlySortScheduler(
            onSent: { nth in analytics(EntryEvents.earlySortSent(nth: nth)) },
            send: { try await entries.previewSort($0) }
        )
        earlySort = scheduler
        scheduler.edited(model.earlySortInput)
    }

    // MARK: - The camera key

    /// The camera, if this phone has one and the person has let us use it. Refused, the key goes to
    /// Settings: there is nothing the app can say about it that the system does not already.
    func takePhoto() {
        guard isFrozen == false, UIImagePickerController.isSourceTypeAvailable(.camera), model.canAddPhotos
        else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isTakingPhoto = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { isTakingPhoto = true }
            }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        @unknown default:
            break
        }
    }

    /// A photo from the camera lands in the cluster exactly as one from the library does.
    /// The 12-megapixel shot is cut down off the main thread; the tile appears when it is written.
    func captured(_ image: UIImage) {
        Task {
            let staged = await ComposerPhotoStaging.stage(
                images: [(id: UUID().uuidString, image: image)],
                in: model.photoDirectory,
                existing: model.photos
            )
            // Anything picked while it was written stays too.
            let added = model.photos.filter { photo in staged.contains { $0.id == photo.id } == false }
            model.setPhotos(Array((staged + added).prefix(EntryDraft.photoLimit)))
            services.analytics(EntryEvents.cameraCaptured(photoCount: model.photos.count))
        }
    }
}

enum V2ComposerTiming {
    /// The receipt's fade (0.25s), and a hair more, before the lists under the sheet are told.
    static let landing: Duration = .milliseconds(350)
}
