import AteKit
import PhotosUI
import SwiftUI

/// **Writing** — the composer's first face. Free prose, and the two things allowed to live inside it:
/// a score, and a diet code after a dish, each a pill *in the sentence* (``InlineTokenEditor``). The
/// place is not in the words: the Place key holds it. Nothing blocks writing, and the words are on
/// disk before the next keystroke (``ComposerModel``, as the current composer runs it).
///
/// The sheet's corners are its two controls: close, a glass disc top left, and the ink tick top
/// right — muted until a place is attached, then stepping three dots while the entry posts. The keys
/// float in one glass capsule above the keyboard (``AteKeyCapsule``); the score slide opens above
/// them, so the keyboard never goes down; staged photos sit just above the keys.
struct V2ComposerWrite: View {
    let app: AppModel
    let presentation: ComposerPresentation
    /// The printed receipt is up over the words: the sheet is free to go on a swipe.
    var isCovered = false
    /// A new entry's words were accepted and the sheet turns to its receipt.
    let onPrinted: (V2ComposerPrinted.Handoff) -> Void

    @State var model: ComposerModel
    @State var pickedItems: [PhotosPickerItem] = []
    @State var isTakingPhoto = false
    /// The tick was tapped and the save has not answered: it steps its dots and takes no second tap.
    @State var isSaving = false
    /// The tick was tapped: the keyboard goes down at once. Back up if the save does not land.
    @State var isHandingOver = false
    /// The save did not land: the composer stays open with everything in it, and asks to try again.
    @State var saveFailed = false
    /// The early sort (`sort-entry`, `preview: true`), made once per composer.
    @State var earlySort: EarlySortScheduler?
    @State var keyboard = KeyboardPresence()
    @State var isChoosingDiet = false
    @State var isConfirmingClose = false
    @Environment(\.openURL) var openURL
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dismiss) var dismiss

    init(
        app: AppModel,
        presentation: ComposerPresentation,
        isCovered: Bool = false,
        onPrinted: @escaping (V2ComposerPrinted.Handoff) -> Void
    ) {
        self.app = app
        self.presentation = presentation
        self.isCovered = isCovered
        self.onPrinted = onPrinted
        let model = ComposerModel(drafts: app.services.drafts, editing: presentation.editing)
        // A nearby chip tapped on a photo sitting: the Place key opens holding it.
        if presentation.editing == nil, let place = presentation.place { _ = model.attach(place: place) }
        _model = State(initialValue: model)
    }

    var services: AteServices { app.services }

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: nil, primary: tick) { requestClose() }
                .allowsHitTesting(isFrozen == false)
            // Frozen from the tick to the hand-off: what is posted is exactly what was on screen at
            // the tap. Nothing dims; the controls just stop answering, to a finger and to VoiceOver.
            VStack(spacing: 0) {
                editor.ateAccessibilityHidden(isFrozen)
                keyBand.ateAccessibilityHidden(isFrozen)
            }
            .allowsHitTesting(isFrozen == false)
        }
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
        // The surface runs behind the keyboard, to the screen's edges.
        .background { AtePalette.surface.ground.ignoresSafeArea() }
        .ateComposerKeyboard(keyboard)
        // Words in it, or a post on its way: a swipe down never throws them away. Close asks.
        .interactiveDismissDisabled(isCovered == false && (model.hasContent || isSaving))
        .confirmationDialog(
            model.editing == nil ? "Discard entry?" : "Discard changes?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { discard() }
            if model.editing == nil {
                Button("Keep draft") { close() }
            }
        }
        .alert("Couldn't reach Ate.", isPresented: $saveFailed) {
            Button("Try again") { post() }
            Button("Cancel", role: .cancel) {}
        }
        .v2PlaceSheet(
            isPresented: $model.isPickingPlace,
            directory: services.places,
            initialQuery: { model.placeQuery },
            selected: { model.place?.id },
            onPick: { place in model.attach(place: place).map(services.analytics) }
        )
        .v2WithSheet(
            isPresented: $model.isPickingCompanions,
            service: services.companions,
            initial: { model.companions },
            analytics: services.analytics,
            onCommit: { model.setCompanions($0) }
        )
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in captured(image) }.ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, items in
            guard items.isEmpty == false else { return }
            stage(items)
        }
        .onChange(of: model.earlySortInput) { old, new in earlySortEdited(from: old, to: new) }
        .onChange(of: model.scoring != nil) { _, isScoring in if isScoring == false { earlySortSettled() } }
        .onChange(of: keyboard.isVisible) { _, isVisible in if isVisible == false { earlySortSettled() } }
        .onAppear {
            services.analytics(EntryEvents.composerOpened(source: origin, isResumingDraft: model.isResumingDraft))
        }
        .task { await stageSuggestedPhotos() }
        .task { startEarlySort() }
        .task { warmUpSorter() }
        .task { await sweepStagedPhotos() }
    }

    // MARK: - The corners

    /// The ink tick: Post for a new entry, Done on an edit. Muted until there is something to save
    /// **and a place**; stepping its dots while it saves.
    private var tick: AteSheetPrimary {
        AteSheetPrimary(
            icon: .check,
            label: model.editing == nil ? "Post" : "Done",
            isEnabled: model.canSave,
            isBusy: isSaving,
            action: post
        )
    }

    /// **The whole composer freezes once a new entry is posted**: the words, every key, the photo X
    /// and close, until the receipt takes over. The request is a snapshot of the tap.
    var isFrozen: Bool { isSaving && model.editing == nil }

    private var origin: ComposerOrigin {
        switch presentation.origin {
        case .tabBar: .tabBar
        case .journalEmpty: .journalEmpty
        case .entryEdit: .entryEdit
        case .photoSuggestion: .photoSuggestion
        }
    }

    // MARK: - The words

    private var editor: some View {
        InlineTokenEditor(
            composition: $model.composition,
            revision: model.revision,
            caretAfterRender: model.caretAfterRender,
            style: .composerProse,
            placeholder: "What did you have today?",
            focusRequest: model.focusRequest,
            isFocusSuspended: isHandingOver,
            selectedTokenID: model.scoring?.id,
            // While the slide is open the focus is the pill, so the words show no caret.
            hidesCaret: model.scoring != nil,
            onTokenTap: { _ = model.reopen($0) },
            onCaretChange: { model.caret = $0 },
            onTokenPromoted: { token, wasDictated, isPhrase in
                model.literalPromoted(token, wasDictated: wasDictated, isPhrase: isPhrase).map(services.analytics)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.scoring != nil {
                // A tap anywhere in the words closes the slide — and only closes it.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { model.dismissScoring() }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.snug)
    }

    // MARK: - Above the keyboard

    /// From the top: the staged photos (or, while it is open, the score slide), then the keys.
    private var keyBand: some View {
        VStack(spacing: 0) {
            if let scoring = model.scoring {
                StarSlider(
                    dishName: scoring.dishName,
                    rating: Binding(
                        get: { model.scoring?.rating },
                        set: { if let rating = $0 { model.slideScore(to: rating) } }
                    ),
                    allowsSix: true
                ) { rating in
                    model.finishScore(at: rating).map(services.analytics)
                }
                .padding(.horizontal, AteMetrics.cardGutter)
                .padding(.bottom, AteMetrics.snug)
                .transition(reduceMotion ? AnyTransition.opacity : V2ComposerMotion.sliderRising)
            } else if model.photos.isEmpty == false {
                AtePhotoCluster(
                    photos: model.photos.map(\.photo),
                    size: .composer,
                    surface: AtePalette.surface.ground,
                    onRemove: removePhoto
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AteMetrics.gutter)
                // Clear of the keys, tilt and all (Eamon, 7 Oct: it sat on the toolbar).
                .padding(.bottom, AteMetrics.snug)
                .accessibilityIdentifier("composer.photos")
                .transition(.opacity)
            }
            AteKeyCapsule(
                place: model.place.flatMap { $0.name.isEmpty ? nil : $0.name },
                isScoring: model.scoring != nil,
                isChoosingDiet: $isChoosingDiet,
                isCameraEnabled: model.canAddPhotos,
                onCamera: {
                    // The camera takes the keyboard's place: close the slide without raising it.
                    model.dismissScoring(refocus: false)
                    takePhoto()
                },
                onScore: scoreKey,
                onPlace: {
                    AteHaptics.key()
                    model.dismissScoring(refocus: false)
                    model.isPickingPlace = true
                },
                onDiet: {
                    AteHaptics.key()
                    model.dismissScoring(refocus: false)
                },
                onCode: pick,
                worn: isChoosingDiet ? model.composition.dishTags(atDisplayOffset: model.caret) : [],
                with: model.companions.map { AteWithPerson(id: $0.userID, handle: $0.handle) },
                onWith: {
                    // Who and where both sit in keys, never in the words (`ate-with.html` 1a).
                    AteHaptics.key()
                    model.dismissScoring(refocus: false)
                    model.isPickingCompanions = true
                },
                library: { libraryKey }
            )
        }
        .ateAnimation(V2ComposerMotion.slider, value: model.scoring?.id)
    }

    /// The library key: the system picker, offering only what the five photos leave room for.
    private var libraryKey: some View {
        PhotosPicker(
            selection: $pickedItems,
            // Picks append to what is staged, so the picker offers only what is left.
            maxSelectionCount: max(1, EntryDraft.photoLimit - model.photos.count),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            AteLibraryKeyFace()
        }
        .disabled(model.canAddPhotos == false)
        .simultaneousGesture(TapGesture().onEnded { model.dismissScoring(refocus: false) })
    }

    /// The Score key: a pill at the caret with the slide open on it — or, while the slide is up, the
    /// slide put away.
    private func scoreKey() {
        AteHaptics.key()
        if model.scoring != nil {
            model.dismissScoring()
        } else {
            services.analytics(model.insertScore())
        }
    }

    /// A code belongs to the dish on its left; with none there, nothing goes in and the refusal is
    /// felt, never written.
    private func pick(_ tag: DietTag) {
        model.dismissScoring(refocus: false)
        guard let added = model.insertTag(tag) else {
            AteHaptics.refused()
            return
        }
        AteHaptics.key()
        services.analytics(added)
    }

    private func removePhoto(_ index: Int) {
        guard isFrozen == false, model.photos.indices.contains(index) else { return }
        AteHaptics.key()
        services.analytics(model.removePhoto(id: model.photos[index].id))
    }

    // MARK: - Closing

    /// Close: straight away when there is nothing to lose; otherwise asked once.
    private func requestClose() {
        guard isFrozen == false else { return }
        if hasUnsavedWords {
            isConfirmingClose = true
        } else {
            close()
        }
    }

    private var hasUnsavedWords: Bool {
        guard let editing = model.editing else { return model.hasContent }
        return model.composition.plain != editing.composition.plain
            || model.place?.id != editing.restaurantID
            || model.photos.map(\.id) != editing.photos.map(\.url)
            || model.companionsChanged
    }

    /// The composer is going away for good: nothing further goes early, and a preview in flight for
    /// words that were not saved is dropped. A new entry's draft stays on disk for next time.
    func close() {
        guard isFrozen == false else { return }
        earlySort?.stop(cancellingInFlight: true)
        dismiss()
    }

    /// "Discard": the draft goes with the sheet. An edit's words were never a draft — the entry stays
    /// as it was.
    private func discard() {
        if model.editing == nil { model.clearDraft() }
        close()
    }
}
