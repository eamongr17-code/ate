import AteKit
import Observation
import SwiftUI

/// **The composer's state**, and every rule about how a token gets into the words.
///
/// The words themselves live in ``EntryComposition`` (AteKit, unit-tested); this holds what the
/// screen needs around them — where the caret is, which token the slider is open on, which photos are
/// attached — and nothing else. The view renders it and calls it.
@MainActor
@Observable
final class ComposerModel: DictationTarget {
    var composition: EntryComposition {
        didSet {
            persist()
            // A pill deleted or undone out from under the slider takes the slider with it.
            if slider.isOpen { slider.retain(onlyIfPresentIn: Set(composition.spans.map(\.token.id))) }
        }
    }
    /// Bumped to force the editor to rebuild its storage after a programmatic change.
    private(set) var revision = 0
    /// Where the caret should land after that rebuild, in display offsets.
    private(set) var caretAfterRender: Int?
    /// Where the caret is now, as the editor reports it.
    var caret = 0
    /// The score slider: which pill it is open on, the value under the finger, and when it closes
    /// (``ScoreSlider``, tested in AteKit).
    private(set) var slider = ScoreSlider()
    var scoring: ScoreSlider.Session? { slider.session }
    /// Up to five, in the order they were picked.
    private(set) var photos: [StagedPhoto] = []
    /// Bumped to pull the keyboard back after the slider or a sheet closes.
    private(set) var focusRequest = 0
    var isPickingPlace = false

    /// The entry's id, minted here and carried to the INSERT — what makes the write idempotent.
    let draftID: UUID
    /// Set when this composer is rewriting an entry that already exists. A draft is never kept for
    /// an edit: the words are already saved somewhere, and a second copy on disk could only rot.
    let editing: ComposerPresentation.EditingEntry?
    private let drafts: any EntryDraftStoring
    private let startedAt: Date
    /// **The place, held by the Place key** — never in the words (ComposerPlaceB, 2026-09-26). Set
    /// only because the person tapped it (design rule 8); the key prints its name.
    private(set) var place: PlaceRef?

    init(drafts: any EntryDraftStoring, editing: ComposerPresentation.EditingEntry? = nil) {
        self.drafts = drafts
        self.editing = editing
        if let editing {
            self.draftID = editing.id
            self.composition = editing.composition
            self.place = editing.restaurantID.map { PlaceRef(id: $0, name: editing.placeName ?? "") }
            self.photos = editing.photos.map(StagedPhoto.init(existing:))
            self.startedAt = Date()
            let end = editing.composition.displayString.utf16.count
            self.caret = end
            self.caretAfterRender = end > 0 ? end : nil
            self.isResumingDraft = false
            return
        }
        let resumed = drafts.load()
        self.draftID = resumed?.id ?? UUID()
        // A draft saved with a place pill in its words has already had it turned back into text
        // and moved here by `EntryDraft`'s own decoding — the migration happens at the read.
        self.composition = resumed?.composition ?? EntryComposition()
        self.place = resumed.flatMap { draft in
            draft.restaurantID.map { PlaceRef(id: $0, name: draft.placeName ?? "") }
        }
        self.startedAt = resumed?.startedAt ?? Date()
        // Resuming puts the caret after the last thing they wrote, not in front of it: a text view
        // opens at offset 0, which would have them typing into the middle of their own sentence.
        let end = (resumed?.composition ?? EntryComposition()).displayString.utf16.count
        self.caret = end
        self.caretAfterRender = end > 0 ? end : nil
        self.isResumingDraft = resumed != nil
        if let resumed {
            photos = ComposerPhotoStaging.restore(
                fileNames: resumed.photoFiles,
                from: drafts.photoDirectory(for: resumed.id)
            )
        }
        #if DEBUG
        if ComposerDebugLaunch.parksCaretAfterToken,
           let pill = composition.displaySpans.first(where: { $0.token.score != nil }) {
            caret = pill.span.endLocation
            caretAfterRender = pill.span.endLocation
        }
        if ComposerDebugLaunch.opensScoring {
            if let span = composition.spans.first(where: { $0.token.score != nil }) {
                slider.open(
                    tokenID: span.token.id,
                    dishName: dishName(before: span.token.id),
                    rating: span.token.score
                )
            } else {
                // The Score key's own path, so the 0.5 opening state can be looked at.
                _ = insertScore()
            }
        }
        #endif
    }

    /// True when the composer opened on words somebody had already started. No prompt, no "you have
    /// a draft" sheet — they are simply back where they were.
    let isResumingDraft: Bool

    /// True once there is anything worth saving. A photos-only entry is legal (`body` may be `''`).
    var hasContent: Bool { composition.isEmpty == false || photos.isEmpty == false }

    /// Done is live once there is something to save **and a place** (Eamon, round 3): a receipt
    /// prints only at a place, and the Place key is the obvious way to give it one. No copy says so.
    var canSave: Bool { hasContent && place?.id != nil }

    /// What an early sort would be asked about right now, or `nil` — never for an edit, whose
    /// sort is not the one Done runs for a new entry.
    var earlySortInput: EarlySortInput? {
        guard editing == nil else { return nil }
        return EarlySortInput(composition: composition, restaurantID: place?.id)
    }

    /// The photo set an edit saves, in order: kept ones by URL, added ones by staged file.
    var editedPhotos: [EntryEdit.Photo] {
        photos.compactMap { photo in
            if let url = photo.remoteURL { return .existing(url: url) }
            guard let fileName = photo.fileName else { return nil }
            return .added(path: photoDirectory.appending(path: fileName).path())
        }
    }

    var photoDirectory: URL { drafts.photoDirectory(for: draftID) }

    var canAddPhotos: Bool { photos.count < EntryDraft.photoLimit }

    /// The entry, as it will be written.
    var draft: EntryDraft {
        EntryDraft(
            id: draftID,
            composition: composition,
            // Every entry is public (Eamon, 2026-09-25: public/private is out of the product). The
            // draft's field stays so drafts already on disk still decode.
            isPublic: true,
            restaurantID: place?.id,
            placeName: place?.name,
            photoFiles: photos.compactMap(\.fileName),
            startedAt: startedAt
        )
    }

    func setPhotos(_ staged: [StagedPhoto]) {
        photos = staged
        persist()
    }

    /// Takes one staged photo back out. Its file stays in the draft's folder until the draft goes —
    /// an undo-free removal should not be the thing that deletes bytes.
    func removePhoto(id: String) -> AnalyticsEvent {
        photos.removeAll { $0.id == id }
        persist()
        return EntryEvents.photoRemoved(photoCount: photos.count)
    }

    /// Every mutation ends here. The words are on disk before the next keystroke, which is what
    /// "your words save instantly" means while they are still being written.
    private func persist() {
        guard editing == nil else { return }
        guard hasContent else {
            drafts.clear(draftID: draftID)
            return
        }
        drafts.save(draft)
    }

    /// Done and gone: the draft has become an entry.
    func clearDraft() {
        drafts.clear(draftID: draftID)
    }

    /// What the save path is handed. The body is the words **verbatim** — `composition.plain`, with
    /// the tokens' own characters still in them, because that is what the person wrote and the
    /// sorter reads (design rule 9).
    func request(from draft: EntryDraft, photoDirectory: URL) -> NewEntryRequest {
        NewEntryRequest(
            id: draft.id,
            body: draft.composition.plain,
            restaurantID: draft.restaurantID,
            photoPaths: draft.photoFiles.map { photoDirectory.appending(path: $0).path() },
            createdAt: draft.startedAt,
            scoreCount: draft.composition.scores.count,
            secondsFromOpen: draft.secondsFromOpen(),
            tagTokens: draft.composition.tagTokens
        )
    }

    // MARK: - The Score key

    /// Puts a token at the caret and opens the slider on it, already reading 0.5.
    ///
    /// The slider opens on the token's **actual** value rather than on nothing: a fresh token is
    /// `Rating.minimum`, so the first star is half filled and the numeral says 0.5. Opening it empty
    /// (the spike's bug) contradicted the words, which already said 0.5.
    func insertScore() -> AnalyticsEvent {
        let token = EntryToken(kind: .score(.minimum))
        let (next, newCaret) = composition.inserting(token, atDisplayOffset: caret)
        apply(next, caret: newCaret)
        slider.open(tokenID: token.id, dishName: dishName(before: token.id), rating: .minimum)
        return EntryEvents.scoreTokenCreated(source: .key)
    }

    /// The editor promoted something the person typed (or dictated) into a token on its own: a
    /// number into a score, or a dietary code after a dish into a tag chip.
    func literalPromoted(_ token: EntryToken, wasDictated: Bool) -> AnalyticsEvent? {
        if let tag = token.tag { return EntryEvents.dishTagAdded(tag) }
        guard token.score != nil else { return nil }
        return EntryEvents.scoreTokenCreated(source: wasDictated ? .dictation : .typed)
    }

    /// Tapping an existing token reopens the thing that made it.
    func reopen(_ token: EntryToken) -> Bool {
        guard let rating = token.score else { return false }
        slider.open(tokenID: token.id, dishName: dishName(before: token.id), rating: rating)
        return true
    }

    /// The finger moved on the slider. The pill in the words follows it **live** — the value is
    /// written into the composition at every half-step, so the words are always what the panel says
    /// and closing it, by any route, has nothing left to commit.
    func slideScore(to rating: Rating) {
        guard let tokenID = slider.session?.id, slider.slide(to: rating) else { return }
        writeScore(rating, into: tokenID)
    }

    /// The finger lifted. The panel stays up for ``ScoreSlider/settleDelay`` so the number that was
    /// set is seen, then goes — unless the finger came back, or the panel moved, in the meantime.
    func finishScore(at rating: Rating) {
        slideScore(to: rating)
        guard let ticket = slider.finish(at: rating) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: ScoreSlider.settleDelay)
            guard let self else { return }
            var closed = false
            withAnimation(.snappy(duration: 0.2)) { closed = self.slider.settle(ticket) }
            if closed { self.focusRequest += 1 }
        }
    }

    /// Closes the slider now: a tap anywhere outside it, another key, Done, the mic. Always works.
    ///
    /// - Parameter refocus: false when something else takes the keyboard's place next (a sheet, the
    ///   camera, dictation, Done) and pulling it back up would only flash.
    func dismissScoring(refocus: Bool = true) {
        guard slider.isOpen else { return }
        withAnimation(.snappy(duration: 0.2)) { slider.dismiss() }
        if refocus { focusRequest += 1 }
    }

    private func writeScore(_ rating: Rating, into tokenID: UUID) {
        composition = composition.replacing(tokenID: tokenID, with: .score(rating))
        revision += 1
        caretAfterRender = nil
    }

    /// Puts the caret back in the words — after a sheet, the slider, or a spell of dictation.
    func focusEditor() {
        focusRequest += 1
    }

    // MARK: - The mic key

    /// Where the caret is in the **words**, which is where a dictation starts. The editor reports the
    /// caret in display offsets; a dictation session works in the plain text, because that is what it
    /// is stitching into.
    var caretPlainOffset: Int { composition.plainOffset(forDisplayOffset: caret) }

    /// One transcript's worth of dictation.
    ///
    /// The revision is deliberately **not** bumped: the editor is behind the voice screen and does not
    /// need to re-render for every partial result, and a full-document rewrite per partial would leave
    /// the person with twenty undo steps for one sentence. The words are on disk either way (the
    /// `didSet` persists them), and the editor takes them in one edit when dictation ends.
    func applyDictation(_ update: DictationSession.Update) {
        composition = update.composition
        caret = composition.displayOffset(forPlainOffset: update.caretPlainOffset)
    }

    /// Dictation ended. **One** revision, so the text view makes one `replace(_:withText:)` for the
    /// whole spell of talking — which is one coherent undo operation, and undoing it gives back exactly
    /// the sentence that was there before the microphone was opened.
    ///
    /// - Parameter refocus: true when the composer is what comes next (the stop button), false when the
    ///   entry is being saved and the keyboard would only flash.
    func commitDictation(refocus: Bool) {
        revision += 1
        caretAfterRender = caret
        if refocus { focusRequest += 1 }
    }

    // MARK: - The Place key

    /// Design rule 8: a place is attached because it was **tapped**, never from location — and it
    /// lives on the key, not in the words (ComposerPlaceB). Typing never makes one; picking one
    /// again replaces it.
    func attach(place: PlaceRef) -> AnalyticsEvent? {
        // Never attach nothing: a place that has not resolved to a row cannot go on an entry.
        guard place.id != nil else { return nil }
        self.place = place
        isPickingPlace = false
        focusRequest += 1
        persist()
        return EntryEvents.placeAttached(source: .picked)
    }

    /// The server said the entry has no place (`place_required`). The key goes back to empty, and
    /// Done with it, so the Place key is once again the obvious next step.
    func placeRefused() {
        place = nil
        persist()
    }

    /// What the place sheet opens pre-filled with: the place already on the key, otherwise nothing —
    /// guessing from the prose is the sorter's job, and a location is never a guess we make.
    var placeQuery: String { place?.name ?? "" }

    // MARK: - The Diet key (prototype)

    /// A tag chip after the current dish (``EntryComposition/insertingTag(_:atDisplayOffset:)``).
    func insertTag(_ tag: DietTag) -> AnalyticsEvent {
        let (next, newCaret) = composition.insertingTag(tag, atDisplayOffset: caret)
        apply(next, caret: newCaret)
        focusRequest += 1
        return EntryEvents.dishTagAdded(tag)
    }

    // MARK: - Typing a number and moving on

    /// Done, and the keyboard's own path: anything still sitting in the words as a bare number — or
    /// a dietary code straight after a dish — becomes a token, exactly as it would when they moved
    /// on by typing.
    @discardableResult
    func promotePendingScoreLiteral() -> AnalyticsEvent? {
        // `pendingScoreLiteral` refuses a span a token already covers. Without that, Done on
        // "tiramisu <pill>" re-found the pill's own digits, replaced it with a new token of the
        // same value, and reported a second `entry_score_token_created` for one score.
        if let found = composition.pendingScoreLiteral(atDisplayOffset: caret) {
            composition = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .score(found.rating)))
            revision += 1
            caretAfterRender = nil
            return EntryEvents.scoreTokenCreated(source: .typed)
        }
        if let found = composition.pendingTagLiteral(atDisplayOffset: caret) {
            composition = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .tag(found.mark)))
            revision += 1
            caretAfterRender = nil
            return EntryEvents.dishTagAdded(found.mark.tag)
        }
        return nil
    }

    // MARK: - Machinery

    private func apply(_ next: EntryComposition, caret newCaret: Int) {
        composition = next
        caretAfterRender = newCaret
        caret = newCaret
        revision += 1
        persist()
    }

    /// The words just before a token, as the name of what is being scored. A stand-in for the
    /// sorter, which is what will actually name the dish — so it is never written anywhere.
    private func dishName(before tokenID: UUID) -> String {
        // ``EntryComposition/dishWords(beforeTokenID:)`` skips a tag chip in front of the pill.
        // Set as a dish's name (`RaterSize` prints "Tagliatelle al ragù"): the first letter up, the
        // rest exactly as written.
        guard let words = composition.dishWords(beforeTokenID: tokenID) else { return "This dish" }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
