import AteKit
import AVFoundation
import PhotosUI
import SwiftUI

/// **`Composer`** — one screen, free prose, and the two things that are allowed to live inside it.
///
/// The whole input model is here: you type the way you'd text a friend, and a score or a place
/// becomes a pill *in the sentence* rather than a field beside it (PRODUCT.md decision 2). Nothing
/// blocks writing — no place step, no dish step, no rating step, and the words are on disk before
/// the next keystroke.
///
/// The screen is a control surface, not the app's ground (`Composer` is white; on a chip ground in
/// dark, `field` recesses to the ink ground so the Place key stays visible — `AtePalette.surface`).
struct ComposerScreen: View {
    let presentation: ComposerPresentation
    let services: AteServices
    /// The entry, the instant its words are accepted — queued or landed. The shell puts it on the
    /// journal and opens it, which is where the receipt prints.
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
        }
        .ateAnimation(.easeInOut(duration: 0.2), value: isDictating)
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
                isFocusSuspended: isDictating,
                undoRequest: undoRequest,
                redoRequest: redoRequest,
                selectedTokenID: model.scoring?.id,
                // While the slider is open the focus is the pill, so the words show no caret.
                hidesCaret: model.scoring != nil,
                onTokenTap: reopen,
                onCaretChange: { model.caret = $0 },
                onScorePromoted: { wasDictated in
                    services.analytics(model.scoreLiteralPromoted(wasDictated: wasDictated))
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

    /// `Composer.dc.html`: camera · library · mic on the left, Score and Place on the right —
    /// `padding:8px 14px 8px 8px; gap:6px; justify-content:space-between`. There is no third group:
    /// every entry is public (Eamon, 2026-09-25), so the visibility key is gone.
    private var toolbar: some View {
        HStack(spacing: Self.toolbarGap) {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera", tint: AtePalette.surface.fg) {
                    // The camera takes the keyboard's place: close the slider without raising it.
                    model.dismissScoring(refocus: false)
                    takePhoto()
                }
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: EntryDraft.photoLimit,
                    selectionBehavior: .ordered,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    AteIcon.library.view(size: 22)
                        .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                        .contentShape(.rect)
                }
                .foregroundStyle(AtePalette.surface.fg)
                .simultaneousGesture(TapGesture().onEnded { model.dismissScoring(refocus: false) })
                .accessibilityLabel("Photo library")
                AteIconButton(icon: .voice, label: "Dictate", tint: AtePalette.surface.fg) {
                    startDictation()
                }
                .accessibilityIdentifier("composer.key.dictate")
            }
            Spacer(minLength: 0)
            HStack(spacing: Self.toolbarGap) {
                ComposerKey(
                    title: "Score",
                    icon: .starFilled,
                    background: AteColor.butter,
                    foreground: AteColor.ink,
                    // `ComposerStars`: while the slider is open the Score key inverts — ink pill,
                    // butter lettering. The Place key never does; the design leaves it in the field
                    // colour whether a place is attached or not.
                    isActive: model.scoring != nil
                ) {
                    // The key is inverted while the panel is up, and pressing it again puts it away.
                    if model.scoring != nil {
                        model.dismissScoring()
                    } else {
                        services.analytics(model.insertScore())
                    }
                }
                ComposerKey(
                    title: "Place",
                    icon: .place,
                    iconSize: 16,
                    background: AtePalette.surface.field,
                    foreground: AtePalette.surface.fg
                ) {
                    model.dismissScoring(refocus: false)
                    model.isPickingPlace = true
                }
            }
        }
        .padding(.vertical, AteMetrics.snug)
        .padding(.leading, AteMetrics.snug)
        .padding(.trailing, Self.toolbarTrailing)
    }

    /// `gap:6px`, between the groups and between the two keys.
    private static let toolbarGap: CGFloat = 6
    /// `padding-right:14px` — the keys sit in from the edge, where the visibility key used to be.
    private static let toolbarTrailing: CGFloat = 14

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
            dismiss()
            // Photos and the sorter, after the screen has gone. Detached from this view's lifetime
            // on purpose: dismissing must not cancel the rest of the entry landing.
            Task.detached {
                await submission.finish(entryID: request.id, photoPaths: request.photoPaths)
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
    private func rewrite(_ editing: ComposerPresentation.EditingEntry) {
        let body = model.composition.plain
        let entries = services.entries
        let id = editing.id
        Task {
            try? await entries.updateBody(entryID: id, body: body)
            isSaving = false
            if let card = try? await entries.entry(id: id) { onSaved(card) }
            dismiss()
            Task.detached {
                _ = try? await entries.sort(entryID: id, force: false)
            }
        }
    }

    private func reopen(_ token: EntryToken) {
        if model.reopen(token) { return }
        if token.place != nil { model.isPickingPlace = true }
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
    private func startDictation() {
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
    private func takePhoto() {
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
