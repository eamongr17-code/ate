import AteKit
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
        VStack(spacing: 0) {
            header
            editor
            toolbar
        }
        .ateSurface()
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
            CameraPicker { image in
                model.setPhotos(ComposerPhotoStaging.stage(
                    images: [(id: UUID().uuidString, image: image)],
                    in: model.photoDirectory,
                    existing: model.photos
                ))
            }
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
            Button(action: done) {
                Text("Done")
                    .ateText(.control)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(AtePalette.surface.fg, in: .capsule)
                    .foregroundStyle(AtePalette.surface.inverted)
            }
            .buttonStyle(.plain)
            .disabled(model.hasContent == false || isSaving)
            .opacity(model.hasContent ? 1 : 0.4)
            .padding(.trailing, AteMetrics.regular)
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
                placeholder: "What did you eat?",
                focusRequest: model.focusRequest,
                undoRequest: undoRequest,
                redoRequest: redoRequest,
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

            if let scoring = model.scoring {
                StarSlider(
                    dishName: scoring.dishName,
                    rating: Binding(
                        get: { model.scoring?.rating },
                        set: { model.scoring?.rating = $0 }
                    )
                ) { rating in
                    model.commitScore(rating, for: scoring.id)
                }
                // `ComposerStars` pins the panel at `top:100px` inside a column that is itself 8
                // below the header.
                .padding(.top, 100 - AteMetrics.snug)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
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
        .height(for: model.composition, width: editorWidth)
    }

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

    /// `Composer.dc.html`: camera · library · mic on the left, Score and Place in the middle,
    /// visibility on the right — three groups, parted by the space between them.
    private var toolbar: some View {
        HStack(spacing: AteMetrics.snug - 2) {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera", tint: AtePalette.surface.fg) {
                    isTakingPhoto = UIImagePickerController.isSourceTypeAvailable(.camera)
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
                .accessibilityLabel("Photo library")
                // Dictation is the keyboard's own key and iOS exposes no way to start it from an
                // app, so this puts the caret back in the words — where the microphone is one tap
                // away — and says nothing.
                AteIconButton(icon: .voice, label: "Dictate", tint: AtePalette.surface.fg) {
                    model.focusEditor()
                }
            }
            Spacer(minLength: 0)
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
                services.analytics(model.insertScore())
            }
            ComposerKey(
                title: "Place",
                icon: .place,
                iconSize: 16,
                background: AtePalette.surface.field,
                foreground: AtePalette.surface.fg
            ) {
                model.isPickingPlace = true
            }
            Spacer(minLength: 0)
            AteIconButton(
                icon: model.isPublic ? .publicEntry : .privateEntry,
                label: model.isPublic ? "Public. Make private" : "Private. Make public",
                size: 21,
                tint: AtePalette.surface.fg
            ) {
                model.isPublic.toggle()
            }
        }
        .padding(AteMetrics.snug)
    }

    // MARK: - Actions

    /// Done. The words go first and alone; the photos and the sorter follow behind, after the screen
    /// is already gone. Nothing about the receipt is allowed to delay the writing being saved.
    private func done() {
        guard isSaving == false, model.hasContent else { return }
        isSaving = true
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

/// A composer toolbar key: **Score** (butter, an accent, so it carries ink) and **Place** (the field
/// colour, so it carries the surface's own foreground).
///
/// The foreground is a parameter for exactly that reason. Hard-wiring ink — which the spike did —
/// made the Place key near-invisible in dark mode: ink text on a plum pill.
struct ComposerKey: View {
    let title: String
    let icon: AteIcon
    /// The artboards size the two keys' icons differently: the Score star is 15, the Place pin 16.
    var iconSize: CGFloat = 15
    let background: Color
    let foreground: Color
    /// Inverted, the way `ComposerStars` draws the Score key while its slider is open: the pill
    /// becomes ink and the lettering becomes the colour the pill used to be.
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.view(size: iconSize)
                Text(title).ateText(.controlSmall)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: AteMetrics.keyHeight)
            .background(isActive ? AtePalette.surface.fg : background, in: .capsule)
            .foregroundStyle(isActive ? background : foreground)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.key.\(title.lowercased())")
    }
}
