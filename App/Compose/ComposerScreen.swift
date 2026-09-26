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

    @State var model: ComposerModel
    @State var pickedItems: [PhotosPickerItem] = []
    @State var isTakingPhoto = false
    /// The microphone is open: `ComposerVoice` sits over the composer, which stays mounted beneath it
    /// so the text view — and its undo stack — is the same one the words come back to.
    @State var isDictating = false
    /// The open microphone, made once when the mic key is tapped and dropped when it closes.
    @State var dictation: DictationController?
    @Environment(\.openURL) var openURL
    @State var isSaving = false
    /// Done could not save: the composer stays open with everything in it, and the pill says
    /// "Try again" — the one word, on the control itself (design rule 1).
    @State var saveFailed = false
    /// The early sort (`sort-entry`, `preview: true`), made once per composer.
    @State var earlySort: EarlySortScheduler?
    /// Set once a new entry's words are accepted: the Summary takes the cover.
    @State var summary: EntryCard?
    /// …and the chips it was sorted with, so "Print it again" re-sorts with the same ones.
    @State var summaryTagTokens: [TagToken] = []
    /// The editor's width, for measuring where the words end.
    @State private var editorWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
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
        // The surface runs behind the keyboard, to the screen's edges: without it the cover's own
        // black shows around the keyboard's rounded corners.
        .background { AtePalette.surface.ground.ignoresSafeArea() }
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
                model.attach(place: place).map(services.analytics)
            }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in captured(image) }
                .ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, items in
            guard items.isEmpty == false else { return }
            Task { await stage(items) }
        }
        .onChange(of: model.earlySortInput) { _, input in earlySort?.edited(input) }
        .onDisappear { earlySort?.stop() }
        .onAppear {
            services.analytics(EntryEvents.composerOpened(
                source: origin,
                isResumingDraft: model.isResumingDraft
            ))
        }
        .task { await stageSuggestedPhotos() }
        .task { startEarlySort() }
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
            AteIconButton(icon: .close, label: "Close") { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            #if DEBUG
            if ComposerDebugLaunch.drivesUndo {
                Button("Undo") { undoRequest += 1 }.accessibilityIdentifier("debug.undo")
                Button("Redo") { redoRequest += 1 }.accessibilityIdentifier("debug.redo")
            }
            #endif
            ComposerDoneButton(
                title: saveFailed ? "Try again" : "Done",
                isEnabled: model.canSave,
                isBusy: isSaving,
                action: done
            )
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
            // While the slider is open the pill is the focus: the cluster steps back rather than
            // having the panel's edge cut across tilted photos.
            photoCluster
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(model.scoring == nil ? 1 : 0)
                .allowsHitTesting(model.scoring == nil)

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
                surface: AtePalette.surface.ground,
                // A long press on a photo takes it back out — the system's own menu, no copy.
                onRemove: { index in
                    guard model.photos.indices.contains(index) else { return }
                    services.analytics(model.removePhoto(id: model.photos[index].id))
                }
            )
            .padding(.top, wordsHeight + Self.wordsGap)
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
}
