import AteKit
import AVFoundation
import PhotosUI
import SwiftUI

/// **`Composer`** — one screen, free prose, and the two things that are allowed to live inside it.
///
/// The whole input model is here: you type the way you'd text a friend, and a score — or a dietary
/// tag after a dish — becomes a pill *in the sentence* rather than a field beside it (PRODUCT.md
/// decision 2). The place is the one thing that is not in the words: the Place key holds it
/// (`ComposerPlaceB`). Nothing blocks writing — no place step, no dish step, no rating step, and the
/// words are on disk before the next keystroke.
///
/// Done hands over to the **Summary** (`SummaryLoading` → `SummaryFinal`): the receipt printing on
/// the coral ground, over the same cover, with the entry page already waiting beneath it.
///
/// The screen is a control surface, not the app's ground (`Composer` is white; on a chip ground in
/// dark, `field` recesses to the ink ground so the Place key stays visible — `AtePalette.surface`).
struct ComposerScreen: View {
    let presentation: ComposerPresentation
    let services: AteServices
    /// The entry, the instant its words are accepted — queued or landed. The shell puts it on the
    /// journal and opens its page under this cover, where the Summary's Done lands.
    var onSaved: (EntryCard) -> Void = { _ in }

    @State private var model: ComposerModel
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isTakingPhoto = false
    /// The microphone is open: `ComposerVoice` sits over the composer, which stays mounted beneath it
    /// so the text view — and its undo stack — is the same one the words come back to.
    @State private var isDictating = false
    /// The open microphone, made once when the mic key is tapped and dropped when it closes.
    @State private var dictation: DictationController?
    @Environment(\.openURL) private var openURL
    @State private var isSaving = false
    /// Set once a new entry's words are accepted: the Summary takes the cover.
    @State private var summary: EntryCard?
    /// …and the chips it was sorted with, so "Print it again" re-sorts with the same ones.
    @State private var summaryTagTokens: [TagToken] = []
    /// The editor's width, for measuring where the words end.
    @State private var editorWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    /// Only the debug undo drive moves these; see ``ComposerDebugLaunch/undoDriveArgument``.
    @State private var undoRequest = 0
    @State private var redoRequest = 0
    @Environment(\.dismiss) private var dismiss

    init(
        presentation: ComposerPresentation,
        services: AteServices,
        onSaved: @escaping (EntryCard) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.services = services
        self.onSaved = onSaved
        _model = State(initialValue: ComposerModel(
            drafts: services.drafts,
            editing: presentation.editing
        ))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                editor
                toolbar
            }
            .ateSurface()
            if isDictating, let dictation {
                VoiceComposerScreen(
                    composer: model,
                    model: dictation,
                    onStop: { isDictating = false },
                    onDone: {
                        isDictating = false
                        done()
                    },
                    onClose: { dismiss() }
                )
                .transition(.opacity)
            }
            if let summary {
                SummaryScreen(
                    card: summary,
                    photos: model.photos.map(\.photo),
                    handle: summary.author?.username ?? "",
                    actions: .live(services.entries, tagTokens: summaryTagTokens),
                    places: services.places,
                    analytics: services.analytics,
                    onDone: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .ateAnimation(.easeInOut(duration: 0.2), value: isDictating)
        .ateAnimation(.easeInOut(duration: 0.25), value: summary?.id)
        .onChange(of: isDictating) { _, isOpen in
            // However the screen went away, the microphone goes with it.
            if isOpen == false {
                dictation?.stop(refocus: false)
                dictation = nil
            }
        }
        .sheet(isPresented: $model.isPickingPlace) {
            PlaceSheet(
                directory: services.places,
                initialQuery: model.placeQuery,
                selected: model.place?.id
            ) { place in
                services.analytics(model.attach(place: place))
            }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in captured(image) }
                .ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, items in
            Task { await stage(items) }
        }
        .onAppear {
            services.analytics(EntryEvents.composerOpened(
                source: origin,
                isResumingDraft: model.isResumingDraft
            ))
        }
        .task { await stageSuggestedPhotos() }
        #if DEBUG
        .task { runDebugLaunch() }
        #endif
    }

    #if DEBUG
    /// The simulator has neither a microphone nor a camera, so the two keys' states are reached from
    /// `simctl launch` instead. See ``ComposerDebugLaunch``.
    private func runDebugLaunch() {
        if ComposerDebugLaunch.fakesCameraCapture, let image = UIImage(named: "Photos/ragu") {
            captured(image)
        }
        if ComposerDebugLaunch.opensVoice { startDictation() }
        if ComposerDebugLaunch.drivesVoiceUndo {
            Task {
                try? await Task.sleep(for: .seconds(7))
                isDictating = false
                try? await Task.sleep(for: .seconds(1.5))
                undoRequest += 1
                guard ComposerDebugLaunch.drivesVoiceRedo else { return }
                try? await Task.sleep(for: .seconds(1.5))
                redoRequest += 1
            }
        }
    }
    #endif

    /// The recogniser. On a simulator, a Debug launch argument swaps in a scripted one — the only
    /// microphone a machine without one has.
    private func makeTranscriber() -> any VoiceTranscribing {
        #if DEBUG
        if ComposerDebugLaunch.fakesDictation {
            let fake = FakeVoiceTranscriber()
            fake.denial = ComposerDebugLaunch.deniesDictation ? .microphone : nil
            return fake
        }
        #endif
        return SystemVoiceTranscriber()
    }

    private var origin: ComposerOrigin {
        switch presentation.origin {
        case .tabBar: .tabBar
        case .journalEmpty: .journalEmpty
        case .entryEdit: .entryEdit
        case .photoSuggestion: .photoSuggestion
        }
    }

    /// A composer opened from `Suggestions` arrives holding a cluster's photos. They are staged the
    /// same way the picker's are — bytes on disk before anything else happens — and they bring
    /// nothing with them but their pixels.
    private func stageSuggestedPhotos() async {
        guard presentation.assetIdentifiers.isEmpty == false, model.photos.isEmpty else { return }
        var images: [(id: String, image: UIImage)] = []
        for identifier in presentation.assetIdentifiers {
            guard let image = await services.photos.image(
                id: identifier, maximumDimension: ComposerPhotoStaging.maximumDimension
            ) else { continue }
            images.append((id: identifier, image: image))
        }
        model.setPhotos(ComposerPhotoStaging.stage(
            images: images, in: model.photoDirectory, existing: model.photos
        ))
    }

    // MARK: - Bands

    private var header: some View {
        HStack {
            AteIconButton(icon: .close, label: "Close") { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            #if DEBUG
            if ComposerDebugLaunch.drivesUndo {
                Button("Undo") { undoRequest += 1 }.accessibilityIdentifier("debug.undo")
                Button("Redo") { redoRequest += 1 }.accessibilityIdentifier("debug.redo")
            }
            #endif
            ComposerDoneButton(isEnabled: model.hasContent, isBusy: isSaving, action: done)
                .accessibilityIdentifier("composer.done")
        }
        .ateContentTop()
        .padding(.leading, AteMetrics.regular)
        .padding(.bottom, AteMetrics.tight)
    }

    private var editor: some View {
        ZStack(alignment: .top) {
            InlineTokenEditor(
                composition: $model.composition,
                revision: model.revision,
                caretAfterRender: model.caretAfterRender,
                style: .composerProse,
                placeholder: Self.placeholder,
                focusRequest: model.focusRequest,
                isFocusSuspended: isDictating || summary != nil,
                undoRequest: undoRequest,
                redoRequest: redoRequest,
                selectedTokenID: model.scoring?.id,
                // While the slider is open the focus is the pill, so the words show no caret.
                hidesCaret: model.scoring != nil,
                onTokenTap: reopen,
                onCaretChange: { model.caret = $0 },
                onTokenPromoted: { token, wasDictated in
                    model.literalPromoted(token, wasDictated: wasDictated).map(services.analytics)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Between the words and the panel: the cluster belongs under the sentence, and the
            // slider opens over both.
            photoCluster
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if model.scoring != nil {
                // A tap anywhere in the writing area outside the panel closes it — and only closes
                // it: the caret does not move, because the focus was the pill. Out to the screen's
                // edges, past the well's inset, so the margins are not a dead zone.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { model.dismissScoring() }
                    .padding(.horizontal, -Self.wellInset)
                    .accessibilityHidden(true)
            }

            if let scoring = model.scoring {
                StarSlider(
                    dishName: scoring.dishName,
                    rating: Binding(
                        get: { model.scoring?.rating },
                        set: { if let rating = $0 { model.slideScore(to: rating) } }
                    )
                ) { rating in
                    model.finishScore(at: rating)
                }
                // `ComposerStars` pins the panel at `top:100px` inside a column that is itself 8
                // below the header.
                .padding(.top, 100 - AteMetrics.snug)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Self.wellInset)
        .padding(.top, AteMetrics.snug)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorWidth = $0 }
    }

    /// Where the words end — measured from the same attributed string the editor draws, so the two
    /// cannot disagree about it.
    private var wordsHeight: CGFloat {
        InlineTokenAttributes(
            style: .composerProse,
            palette: .surface,
            dynamicTypeSize: dynamicTypeSize,
            displayScale: displayScale,
            colorScheme: colorScheme
        )
        // Nothing written yet, the placeholder is what the photos hang under — a photos-only draft
        // (a camera shot first) otherwise drew its cluster over "What did you eat?".
        .height(
            for: model.composition.isEmpty ? EntryComposition(plain: Self.placeholder, spans: []) : model.composition,
            width: editorWidth
        )
    }

    private static let placeholder = "What did you eat?"
    /// The writing well's side inset.
    private static let wellInset: CGFloat = 22

    /// Design rule 6: the mess is tilt and overlap, in a small static cluster. The composer's is the
    /// biggest of the three (90pt), and it sits on the control surface, so the separating ring is
    /// drawn in that colour rather than in the app's ground.
    ///
    /// It hangs off the bottom of the words — the artboard's column is prose, then photos, with an
    /// 18 gap. The editor itself fills the well so the blank space under it still takes a tap, so
    /// the cluster is placed rather than stacked.
    @ViewBuilder
    private var photoCluster: some View {
        if model.photos.isEmpty == false {
            PhotoCluster(
                photos: model.photos.map(\.photo),
                side: AteMetrics.clusterPhotoComposer,
                surface: AtePalette.surface.ground
            )
            .padding(.top, wordsHeight + Self.wordsGap)
            .allowsHitTesting(false)
        }
    }

    /// `Composer.dc.html`'s `gap:18px` between the words and the photos.
    private static let wordsGap: CGFloat = 18

    /// `Composer.dc.html`'s toolbar — ``ComposerToolbar``.
    private var toolbar: some View {
        ComposerToolbar(
            model: model,
            pickedItems: $pickedItems,
            analytics: services.analytics,
            onCamera: takePhoto,
            onDictate: startDictation
        )
    }

    // MARK: - Actions

    /// Done. The words go first and alone; the photos and the sorter follow behind, after the screen
    /// is already gone. Nothing about the receipt is allowed to delay the writing being saved.
    private func done() {
        guard isSaving == false, model.hasContent else { return }
        isSaving = true
        model.dismissScoring(refocus: false)
        model.promotePendingScoreLiteral().map(services.analytics)
        if let editing = model.editing {
            rewrite(editing)
            return
        }
        let draft = model.draft
        let request = model.request(from: draft, photoDirectory: model.photoDirectory)
        let submission = services.submission

        Task {
            let result = await submission.submit(request)
            isSaving = false
            guard let card = result.card else {
                // The server refused. The draft stays exactly where it is, with every word in it.
                return
            }
            model.clearDraft()
            onSaved(card)
            if case .saved = result {
                // The Summary takes the cover; the entry page is already beneath it.
                summaryTagTokens = request.tagTokens
                summary = card
            } else {
                // Queued offline: there is no order number to print yet (the server allocates
                // it), so there is no receipt to show — the entry page carries the wait.
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
            tagTokens: model.composition.tagTokens
        )
        let entries = services.entries
        let analytics = services.analytics
        Task {
            if edit.changesPlace { analytics(EntryEvents.corrected(.place)) }
            let card = (try? await edit.saveWordsAndPlace(to: entries)).flatMap { $0 }
            isSaving = false
            if let card { onSaved(card) }
            dismiss()
            Task.detached { await edit.sort(on: entries) }
        }
    }

    /// Tapping a pill reopens what made it — the slider, for a score. A tag chip has nothing to
    /// reopen: backspace takes it, as it would a word.
    private func reopen(_ token: EntryToken) {
        _ = model.reopen(token)
    }

    private func stage(_ items: [PhotosPickerItem]) async {
        let staged = await ComposerPhotoStaging.stage(
            items,
            in: model.photoDirectory,
            existing: model.photos
        )
        model.setPhotos(staged)
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
    private func captured(_ image: UIImage) {
        model.setPhotos(ComposerPhotoStaging.stage(
            images: [(id: UUID().uuidString, image: image)],
            in: model.photoDirectory,
            existing: model.photos
        ))
        services.analytics(EntryEvents.cameraCaptured(photoCount: model.photos.count))
    }
}
