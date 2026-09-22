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
    @State private var isSaving = false
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
            .presentationDetents([.large])
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
    }

    private var origin: ComposerOrigin {
        switch presentation.origin {
        case .tabBar: .tabBar
        case .journalEmpty: .journalEmpty
        case .entryEdit: .entryEdit
        }
    }

    // MARK: - Bands

    private var header: some View {
        HStack {
            AteIconButton(icon: .close, label: "Close") { dismiss() }
            Spacer(minLength: AteMetrics.snug)
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
        }
        .padding(.top, AteMetrics.contentTop)
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
                onTokenTap: reopen,
                onCaretChange: { model.caret = $0 },
                onScorePromoted: { wasDictated in
                    services.analytics(model.scoreLiteralPromoted(wasDictated: wasDictated))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                .padding(.top, 60)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, AteMetrics.snug)
        .overlay(alignment: .bottomLeading) { photoCluster }
    }

    /// Design rule 6: the mess is tilt and overlap, in a small static cluster. The composer's is the
    /// biggest of the three (90pt), and it sits on the control surface, so the separating ring is
    /// drawn in that colour rather than in the app's ground.
    @ViewBuilder
    private var photoCluster: some View {
        if model.photos.isEmpty == false {
            PhotoCluster(
                photos: model.photos.map(\.photo),
                side: AteMetrics.clusterPhotoComposer,
                surface: AtePalette.surface.ground
            )
            .padding(.leading, 22)
            .padding(.bottom, AteMetrics.snug)
        }
    }

    private var toolbar: some View {
        HStack(spacing: AteMetrics.snug - 2) {
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
                background: AtePalette.surface.field,
                foreground: AtePalette.surface.fg
            ) {
                model.isPickingPlace = true
            }
            Spacer(minLength: 0)
            AteIconButton(
                icon: model.isPublic ? .publicEntry : .privateEntry,
                label: model.isPublic ? "Public. Make private" : "Private. Make public"
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

    /// Editing an entry that already exists: the body is rewritten in place and the sorter is asked
    /// again, because the structure underneath is derived from these words and nothing else.
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
                _ = try? await entries.sort(entryID: id, force: true)
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
    let background: Color
    let foreground: Color
    /// Inverted, the way `ComposerStars` draws the Score key while its slider is open: the pill
    /// becomes ink and the lettering becomes the colour the pill used to be.
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.view(size: 15, weight: .semibold)
                Text(title).ateText(.controlSmall)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: AteMetrics.keyHeight)
            .background(isActive ? AtePalette.surface.fg : background, in: .capsule)
            .foregroundStyle(isActive ? background : foreground)
        }
        .buttonStyle(.plain)
    }
}
