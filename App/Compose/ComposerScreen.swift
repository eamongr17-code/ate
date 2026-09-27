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
/// Post hands over to the **Summary**: "Posting…" holds while the sorter works (``PostHold``), then
/// the coral ground comes up over the same cover and the receipt enters whole — never printed and
/// then reshaped (round 5). The entry page is already waiting beneath it.
///
/// The screen is a control surface, not the app's ground (`Composer` is white; on a chip ground in
/// dark, `field` recesses to the ink ground so the Place key stays visible — `AtePalette.surface`).
struct ComposerScreen: View {
    let presentation: ComposerPresentation
    let services: AteServices
    /// The entry, the instant its words are accepted — queued or landed. The shell puts it on the
    /// journal and opens its page under this cover, where the Summary's Done lands.
    var onSaved: (EntryCard) -> Void = { _ in }

    @State var model: ComposerModel
    @State var pickedItems: [PhotosPickerItem] = []
    @State var isTakingPhoto = false
    /// The microphone is open: `ComposerVoice` sits over the composer. **Parked** (round 4,
    /// ``VoiceParking``): nothing reaches it while voice mode is out of the product.
    @State var isDictating = false
    /// The open microphone, made once when dictation starts and dropped when it closes.
    @State var dictation: DictationController?
    @Environment(\.openURL) var openURL
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Post was tapped and has not handed over yet: the pill says "Posting…".
    @State var isSaving = false
    /// Done was tapped: the keyboard goes down at once, rather than sitting up over a screen that is
    /// about to be the Summary (round 4, bug a). Back up if the save does not land.
    @State var isHandingOver = false
    /// Done could not save: the composer stays open with everything in it, and the pill says
    /// "Try again" — the one word, on the control itself (design rule 1).
    @State var saveFailed = false
    /// The early sort (`sort-entry`, `preview: true`), made once per composer.
    @State var earlySort: EarlySortScheduler?
    /// Set once a new entry's words are accepted: the Summary takes the cover.
    @State var summary: EntryCard?
    /// The entry as the sort leaves it — filled by Post, waited on by the hold and then the Summary.
    @State var summarySorted: Latch<EntryCard?>?
    /// …and the chips and 6s it was sorted with, so "Print it again" re-sorts with the same ones.
    @State var summaryTagTokens: [TagToken] = []
    @State var summarySixTokens: [TagToken] = []
    @State var keyboard = KeyboardPresence()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Only the debug undo drive moves these; see ``ComposerDebugLaunch/undoDriveArgument``.
    @State private var undoRequest = 0
    @State private var redoRequest = 0
    @Environment(\.dismiss) var dismiss

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
                // Frozen from the Post tap to the hand-off: what is posted is exactly what was on
                // screen at the tap. Nothing dims and nothing new appears; the controls just stop
                // answering — to a finger, and to VoiceOver (the photo X and Close by their guards).
                Group {
                    editor.ateAccessibilityHidden(isFrozen)
                    photoStrip
                    toolbar.ateAccessibilityHidden(isFrozen)
                }
                .allowsHitTesting(isFrozen == false)
            }
            .ateSurface()
            .ateComposerKeyboard(keyboard)
            if isDictating, let dictation {
                VoiceComposerScreen(
                    composer: model,
                    model: dictation,
                    onStop: { isDictating = false },
                    onDone: {
                        isDictating = false
                        post()
                    },
                    onClose: { close() }
                )
                .transition(.opacity)
            }
            if let summary {
                SummaryScreen(
                    card: summary,
                    photos: model.photos.map(\.photo),
                    handle: summary.author?.username ?? "",
                    actions: .live(services.entries, tagTokens: summaryTagTokens, sixTokens: summarySixTokens),
                    sorted: summarySorted,
                    photoLibrary: services.photos,
                    places: services.places,
                    analytics: services.analytics,
                    onDone: { dismiss() },
                    onUpdated: onSaved
                )
                // Laid out whole before it is shown — never grown out of the corner mid-transition
                // (round 4, bug a: a grey Share pill at the top-left and a stray letter) — and blind
                // to the keyboard, which is on its way down under it.
                .geometryGroup()
                .ignoresSafeArea(.keyboard)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // The surface runs behind the keyboard, to the screen's edges: without it the cover's own
        // black shows around the keyboard's rounded corners.
        .background { AtePalette.surface.ground.ignoresSafeArea() }
        .ateAnimation(.easeInOut(duration: 0.2), value: isDictating)
        .onChange(of: isDictating) { _, isOpen in
            // However the screen went away, the microphone goes with it.
            if isOpen == false {
                dictation?.stop(refocus: false)
                dictation = nil
            }
        }
        .atePlaceSheet(
            isPresented: $model.isPickingPlace,
            directory: services.places,
            initialQuery: { model.placeQuery },
            selected: { model.place?.id },
            onPick: { place in model.attach(place: place).map(services.analytics) }
        )
        .fullScreenCover(isPresented: $isTakingPhoto) {
            cameraCover
        }
        .onChange(of: pickedItems) { _, items in
            guard items.isEmpty == false else { return }
            stage(items)
        }
        .onChange(of: model.earlySortInput) { _, input in earlySort?.edited(input) }
        // No `onDisappear` stop: presenting the camera's cover disappears this view, and the early
        // sort must survive it. It stops on Done and on close (``close()``); a dismissed composer's
        // scheduler is released with its state, and its tasks hold it weakly.
        .onAppear {
            services.analytics(EntryEvents.composerOpened(
                source: origin,
                isResumingDraft: model.isResumingDraft
            ))
        }
        .task { await stageSuggestedPhotos() }
        .task { startEarlySort() }
        .task { await sweepStagedPhotos() }
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
        if ComposerDebugLaunch.fakesCameraCover { isTakingPhoto = true }
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
    func makeTranscriber() -> any VoiceTranscribing {
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
            AteIconButton(icon: .close, label: "Close") { close() }
                // The entry is already saved by the time this could mean anything: not a cancel.
                .allowsHitTesting(isFrozen == false)
            Spacer(minLength: AteMetrics.snug)
            #if DEBUG
            if ComposerDebugLaunch.drivesUndo {
                Button("Undo") { undoRequest += 1 }.accessibilityIdentifier("debug.undo")
                Button("Redo") { redoRequest += 1 }.accessibilityIdentifier("debug.redo")
            }
            #endif
            ComposerPostButton(
                title: postTitle,
                isEnabled: model.canSave,
                isBusy: isSaving,
                action: post
            )
                .accessibilityIdentifier("composer.post")
        }
        .ateContentTop()
        .padding(.leading, AteMetrics.regular)
        .padding(.bottom, AteMetrics.tight)
    }

    /// **The whole composer freezes once a new entry is posted** (round 5, QA): the words, every
    /// key, the photo X, the library, the camera, Place and Close, until the Summary takes over.
    /// The request is a snapshot of the tap, so anything touched after it would silently not count.
    var isFrozen: Bool { isSaving && model.editing == nil }

    /// "Post"; "Posting…" while it holds; "Done" on an edit — the entry is already posted.
    private var postTitle: String {
        if saveFailed { return "Try again" }
        if model.editing != nil { return "Done" }
        return isSaving ? "Posting…" : "Post"
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
                isFocusSuspended: isDictating || isHandingOver || summary != nil,
                undoRequest: undoRequest,
                redoRequest: redoRequest,
                selectedTokenID: model.scoring?.id,
                // While the slider is open the focus is the pill, so the words show no caret.
                hidesCaret: model.scoring != nil,
                onTokenTap: reopen,
                onCaretChange: { model.caret = $0 },
                onTokenPromoted: { token, wasDictated, isPhrase in
                    model.literalPromoted(token, wasDictated: wasDictated, isPhrase: isPhrase)
                        .map(services.analytics)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                    ),
                    allowsSix: true
                ) { rating in
                    model.finishScore(at: rating).map(services.analytics)
                }
                // `ComposerStars` pins the panel at `top:100px` inside a column that is itself 8
                // below the header.
                // At the accessibility sizes the panel is several times taller: it opens at the top of
                // the well, and a panel taller than the well runs on over it rather than pushing the
                // toolbar down under the keyboard.
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 0 : 100 - AteMetrics.snug)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .padding(.horizontal, Self.wellInset)
        .padding(.top, AteMetrics.snug)
    }

    private static let placeholder = "What did you eat?"
    /// The writing well's side inset.
    private static let wellInset: CGFloat = 22

    /// Design rule 6: the mess is tilt and overlap, in a small static cluster. The composer's is the
    /// biggest of the three (90pt), and it sits on the control surface, so the separating ring is
    /// drawn in that colour rather than in the app's ground.
    ///
    /// **Anchored at the foot of the writing area** (round 4), just above the toolbar: the words
    /// scroll above it and never run under it, and it does not move while they are typed. Each photo
    /// carries a small X; a long press still offers the system's Remove.
    @ViewBuilder
    private var photoStrip: some View {
        if model.photos.isEmpty == false {
            PhotoCluster(
                photos: model.photos.map(\.photo),
                side: AteMetrics.clusterPhotoComposer,
                surface: AtePalette.surface.ground,
                topPadding: Self.stripTop,
                bottomPadding: AteMetrics.hairspace,
                onRemove: { index in
                    guard isFrozen == false, model.photos.indices.contains(index) else { return }
                    AteHaptics.key()
                    services.analytics(model.removePhoto(id: model.photos[index].id))
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.wellInset)
            .accessibilityIdentifier("composer.photos")
            .transition(.opacity)
        }
    }

    /// Room above the tiles for their tilt and for each one's X, which sits over its corner.
    private static let stripTop: CGFloat = 12

    /// `Composer.dc.html`'s toolbar — ``ComposerToolbar``.
    private var toolbar: some View {
        ComposerToolbar(
            model: model,
            pickedItems: $pickedItems,
            analytics: services.analytics,
            onCamera: takePhoto
        )
    }

    /// The composer is going away for good: nothing further goes early, and a preview in flight for
    /// words that were not saved is dropped.
    func close() {
        guard isFrozen == false else { return }
        earlySort?.stop(cancellingInFlight: true)
        dismiss()
    }

    @ViewBuilder
    private var cameraCover: some View {
        #if DEBUG
        if ComposerDebugLaunch.fakesCameraCover {
            // The simulator has no camera: a stand-in cover that "shoots" the ragù and closes, so the
            // cover's effect on the composer beneath it (the early sort) can be driven.
            Color.black.ignoresSafeArea()
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    if let image = UIImage(named: "Photos/ragu") { captured(image) }
                    isTakingPhoto = false
                }
        } else {
            CameraPicker { image in captured(image) }.ignoresSafeArea()
        }
        #else
        CameraPicker { image in captured(image) }.ignoresSafeArea()
        #endif
    }
}
