import AteKit
import AVFoundation
import PhotosUI
import SwiftUI

/// The composer's actions — Done (a new entry or an edit), the early sort, photos, and the camera
/// key. Split from ``ComposerScreen`` for length; the state is the screen's own.
extension ComposerScreen {
    // MARK: - Actions

    /// Done. The words go first and alone; the photos and the sorter follow behind, after the screen
    /// is already gone. Nothing about the receipt is allowed to delay the writing being saved.
    ///
    /// **The handover is one clean step** (round 4, bug a): the keyboard goes down the moment Done is
    /// tapped, the Summary fades in over a composer that has stopped moving, and the shell's own work
    /// (the journal, the tab under the cover) waits until the Summary is up rather than competing
    /// with it for the frame.
    func done() {
        guard isSaving == false, model.canSave else { return }
        isSaving = true
        saveFailed = false
        isHandingOver = true
        // Nothing further goes early; a preview already out for these words is left to land, and
        // the real sort reuses its plan.
        earlySort?.stop()
        model.dismissScoring(refocus: false)
        model.promotePendingScoreLiteral().map(services.analytics)

        Task {
            // A pick still being written is part of the entry: it goes up with it, not without it.
            while model.hasPendingPhotos {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let editing = model.editing {
                rewrite(editing)
            } else {
                await submit()
            }
        }
    }

    private func submit() async {
        let draft = model.draft
        let request = model.request(from: draft, photoDirectory: model.photoDirectory)
        let submission = services.submission
        let analytics = services.analytics

        let result = await submission.submit(request)
        isSaving = false
        guard let card = result.card else {
            giveBackTheKeyboard()
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
        if case .saved = result {
            // The Summary takes the cover; the entry page is already beneath it.
            summaryTagTokens = request.tagTokens
            summarySixTokens = request.sixTokens
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { summary = card }
            // The shell's half of the handover — the journal, the tab — once the Summary is up.
            let land = onSaved
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                land(card)
            }
        } else {
            // Queued offline: there is no order number to print yet (the server allocates
            // it), so there is no receipt to show — the journal's slip carries the wait.
            onSaved(card)
            dismiss()
        }
        // Photos and the sorter, while the receipt prints. Detached from this view's lifetime on
        // purpose: Done on the Summary must not cancel the rest of the entry landing.
        Task.detached {
            await submission.finish(
                entryID: request.id,
                photoPaths: request.photoPaths,
                tagTokens: request.tagTokens,
                sixTokens: request.sixTokens
            )
        }
    }

    /// A save that did not land: the composer is the writing surface again.
    private func giveBackTheKeyboard() {
        isHandingOver = false
        model.focusEditor()
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
    /// `tag_tokens` — the one case where forcing is the point — with the entry's 6s beside them.
    private func rewrite(_ editing: ComposerPresentation.EditingEntry) {
        let edit = EntryEdit(
            entryID: editing.id,
            body: model.composition.plain,
            originalRestaurantID: editing.restaurantID,
            restaurantID: model.place?.id,
            tagTokens: model.composition.tagTokens,
            sixTokens: model.composition.sixTokens,
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
                giveBackTheKeyboard()
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

    /// **Library picks appear at once** (round 4): each is a still tile in the cluster the moment the
    /// picker closes, its preview lands as soon as there is one — from the photo library's own cache
    /// when it has been shared with us, otherwise from the first decode — and the bytes are written
    /// behind it. The picker clears straight away, so the next trip to it offers only what is left.
    func stage(_ items: [PhotosPickerItem]) {
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
                if let staged {
                    model.finishPhoto(id: id, fileName: staged.fileName, image: staged.image)
                } else {
                    model.dropPhoto(id: id)
                }
            }
        }
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

// MARK: - Voice (parked) and the camera key

/// **Voice mode is parked** (round 4). The mic key is off the toolbar and nothing in the product
/// reaches `ComposerVoice`, so neither the microphone nor the speech-recognition permission is ever
/// asked for. The code stays whole — `VoiceComposerScreen`, `VoiceTranscriber`,
/// `DictationController` and their tests — and comes back by flipping this one constant (and putting
/// the key back in ``ComposerToolbar``). The keyboard's own dictation is the voice path meanwhile.
enum VoiceParking {
    static let isEnabled = false
}

extension ComposerScreen {

    /// The keyboard goes down and `ComposerVoice` comes up over the words. The editor stays exactly
    /// where it is underneath; dictation writes into the same model, and the text view takes it all
    /// back in one edit when the microphone closes. Unreachable while ``VoiceParking`` holds.
    func startDictation() {
        guard VoiceParking.isEnabled, isDictating == false else { return }
        model.dismissScoring(refocus: false)
        dictation = DictationController(
            target: model, transcriber: makeTranscriber(), analytics: services.analytics
        )
        isDictating = true
    }

    // MARK: - The camera key

    /// The camera, if this phone has one and the person has let us use it. Refused, the key goes to
    /// Settings: there is nothing the app can say about it that the system does not already.
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
