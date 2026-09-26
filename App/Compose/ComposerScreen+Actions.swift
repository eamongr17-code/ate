import AteKit
import AVFoundation
import PhotosUI
import SwiftUI

/// The composer's actions — Done (a new entry or an edit), the early sort, photos, and the mic and
/// camera keys. Split from ``ComposerScreen`` for length; the state is the screen's own.
extension ComposerScreen {
    // MARK: - Actions

    /// Done. The words go first and alone; the photos and the sorter follow behind, after the screen
    /// is already gone. Nothing about the receipt is allowed to delay the writing being saved.
    func done() {
        guard isSaving == false, model.canSave else { return }
        isSaving = true
        saveFailed = false
        // Nothing further goes early; a preview already out for these words is left to land, and
        // the real sort reuses its plan.
        earlySort?.stop()
        model.dismissScoring(refocus: false)
        model.promotePendingScoreLiteral().map(services.analytics)
        if let editing = model.editing {
            rewrite(editing)
            return
        }
        let draft = model.draft
        let request = model.request(from: draft, photoDirectory: model.photoDirectory)
        let submission = services.submission
        let analytics = services.analytics

        Task {
            let result = await submission.submit(request)
            isSaving = false
            guard let card = result.card else {
                if result.isPlaceRequired {
                    // Unreachable past the Done gate, but if the server says it: no place, so the
                    // Place key is empty again and Done waits on it — not a retry that cannot work.
                    model.placeRefused()
                    analytics(EntryEvents.saveFailed(isEdit: false, reason: "place_required"))
                    return
                }
                // The server refused. The composer stays open, the draft stays exactly where it is
                // with every word in it, and Done offers to try again.
                saveFailed = true
                analytics(EntryEvents.saveFailed(isEdit: false, reason: "rejected"))
                return
            }
            AteHaptics.success()
            model.clearDraft()
            onSaved(card)
            if case .saved = result {
                // The Summary takes the cover; the entry page is already beneath it.
                summaryTagTokens = request.tagTokens
                summary = card
            } else {
                // Queued offline: there is no order number to print yet (the server allocates
                // it), so there is no receipt to show — the journal's slip carries the wait.
                dismiss()
            }
            // Photos and the sorter, while the receipt prints. Detached from this view's lifetime on
            // purpose: Done on the Summary must not cancel the rest of the entry landing.
            Task.detached {
                await submission.finish(
                    entryID: request.id, photoPaths: request.photoPaths, tagTokens: request.tagTokens
                )
            }
        }
    }

    /// Editing an entry that already exists: the body is rewritten in place, and the sorter is asked
    /// again **without forcing**.
    ///
    /// `apply_entry_sort` deletes and rebuilds every review for an entry, so forcing a re-sort here
    /// threw away corrections the person had already made — fix a dish, come back a day later to fix
    /// a typo, and the dish silently reverts. A non-forced call is a no-op on a sorted entry and
    /// still picks up an entry that never got sorted, which is the honest half of the job. Re-sorting
    /// an edit *without* losing corrections needs the server to merge rather than rebuild; backend
    /// has it.
    ///
    /// Everything the keys set is kept (``EntryEdit``): a place picked on the Place key is attached
    /// with `correct_entry_place`, and tag chips typed during the edit go to a forced re-sort as
    /// `tag_tokens` — the one case where forcing is the point.
    private func rewrite(_ editing: ComposerPresentation.EditingEntry) {
        let edit = EntryEdit(
            entryID: editing.id,
            body: model.composition.plain,
            originalRestaurantID: editing.restaurantID,
            restaurantID: model.place?.id,
            tagTokens: model.composition.tagTokens,
            originalPhotos: editing.photos,
            photos: model.editedPhotos,
            // Against the chips the edit opened with: only a NEW chip forces the re-sort.
            tags: EditTagDiff(original: editing.composition, current: model.composition, items: editing.items)
        )
        let entries = services.entries
        let analytics = services.analytics
        Task {
            do {
                let card = try await edit.save(to: entries)
                isSaving = false
                if edit.changesPlace { analytics(EntryEvents.corrected(.place)) }
                AteHaptics.success()
                onSaved(card)
                dismiss()
                Task.detached { await edit.sort(on: entries) }
            } catch {
                // A failed edit never closes the composer and never loses a change: everything is
                // still on screen, and the pill says "Try again". Every step is idempotent.
                isSaving = false
                saveFailed = true
                analytics(EntryEvents.saveFailed(
                    isEdit: true, reason: EntryWriteFailure.of(error).isRetryable ? "offline" : "rejected"
                ))
            }
        }
    }

    /// Tapping a pill reopens what made it — the slider, for a score. A tag chip has nothing to
    /// reopen: backspace takes it, as it would a word.
    func reopen(_ token: EntryToken) {
        _ = model.reopen(token)
    }

    /// Library picks append to the cluster; the picker then clears, so the next trip to it starts
    /// fresh rather than re-offering (and re-staging) what is already there.
    func stage(_ items: [PhotosPickerItem]) async {
        let added = await ComposerPhotoStaging.stage(
            items,
            in: model.photoDirectory,
            existing: model.photos
        )
        // Merged at commit time, not overwritten with the list as it was when loading began.
        model.addPhotos(added)
        pickedItems = []
    }

    /// The early sort, wired to the entry service and counted.
    func startEarlySort() {
        guard earlySort == nil, model.editing == nil else { return }
        let entries = services.entries
        let analytics = services.analytics
        let scheduler = EarlySortScheduler(
            onSent: { nth in
                analytics(EntryEvents.earlySortSent(nth: nth))
                #if DEBUG
                print("[ate] early sort sent #\(nth)")
                #endif
            },
            send: { try await entries.previewSort($0) }
        )
        earlySort = scheduler
        scheduler.edited(model.earlySortInput)
    }
}

// MARK: - The mic key and the camera key

extension ComposerScreen {

    /// The keyboard goes down and `ComposerVoice` comes up over the words. The editor stays exactly
    /// where it is underneath; dictation writes into the same model, and the text view takes it all
    /// back in one edit when the microphone closes.
    func startDictation() {
        guard isDictating == false else { return }
        model.dismissScoring(refocus: false)
        dictation = DictationController(
            target: model, transcriber: makeTranscriber(), analytics: services.analytics
        )
        isDictating = true
    }

    // MARK: - The camera key

    /// The camera, if this phone has one and the person has let us use it. Refused, the key goes to
    /// Settings — the same answer the mic key gives, and for the same reason: there is nothing the app
    /// can say about it that the system does not already.
    func takePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), model.canAddPhotos else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isTakingPhoto = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { isTakingPhoto = true }
            }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        @unknown default:
            break
        }
    }

    /// A photo from the camera lands in the cluster exactly as one from the library does: the same
    /// staging, the same file on disk, the same order.
    func captured(_ image: UIImage) {
        model.setPhotos(ComposerPhotoStaging.stage(
            images: [(id: UUID().uuidString, image: image)],
            in: model.photoDirectory,
            existing: model.photos
        ))
        services.analytics(EntryEvents.cameraCaptured(photoCount: model.photos.count))
    }
}
