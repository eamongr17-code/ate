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
    /// Which token the slider is open on, and the value under the finger.
    struct Scoring: Identifiable, Equatable {
        let id: UUID
        var dishName: String
        var rating: Rating?
    }

    var composition: EntryComposition {
        didSet { persist() }
    }
    /// Bumped to force the editor to rebuild its storage after a programmatic change.
    private(set) var revision = 0
    /// Where the caret should land after that rebuild, in display offsets.
    private(set) var caretAfterRender: Int?
    /// Where the caret is now, as the editor reports it.
    var caret = 0
    var scoring: Scoring?
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
    private var restaurantID: UUID?

    init(drafts: any EntryDraftStoring, editing: ComposerPresentation.EditingEntry? = nil) {
        self.drafts = drafts
        self.editing = editing
        if let editing {
            self.draftID = editing.id
            self.composition = Self.composition(for: editing)
            self.restaurantID = editing.restaurantID
            self.startedAt = Date()
            let end = Self.composition(for: editing).displayString.utf16.count
            self.caret = end
            self.caretAfterRender = end > 0 ? end : nil
            self.isResumingDraft = false
            return
        }
        let resumed = drafts.load()
        self.draftID = resumed?.id ?? UUID()
        self.composition = resumed?.composition ?? EntryComposition()
        self.restaurantID = resumed?.restaurantID
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
                scoring = Scoring(
                    id: span.token.id,
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
            restaurantID: restaurantID,
            photoFiles: photos.map(\.fileName),
            startedAt: startedAt
        )
    }

    func setPhotos(_ staged: [StagedPhoto]) {
        photos = staged
        persist()
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

    /// An existing entry's words, with the place token put back where the person named it. Scores
    /// are deliberately NOT re-tokenised here: the sorter decided which numbers were scores, and
    /// re-deciding on the client would be a second opinion about somebody's own sentence. They stay
    /// as the plain digits they are, and typing beside them promotes them exactly as before.
    private static func composition(for editing: ComposerPresentation.EditingEntry) -> EntryComposition {
        guard let name = editing.placeName,
              let range = editing.body.range(of: name),
              let lower = range.lowerBound.samePosition(in: editing.body.utf16) else {
            return EntryComposition(plain: editing.body, spans: [])
        }
        let location = editing.body.utf16.distance(from: editing.body.utf16.startIndex, to: lower)
        return EntryComposition(
            plain: editing.body,
            spans: [EntryTokenSpan(
                token: EntryToken(kind: .place(PlaceRef(id: editing.restaurantID, name: name))),
                span: TextSpan(location: location, length: name.utf16.count)
            )]
        )
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
            secondsFromOpen: draft.secondsFromOpen()
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
        scoring = Scoring(id: token.id, dishName: dishName(before: token.id), rating: .minimum)
        return EntryEvents.scoreTokenCreated(source: .key)
    }

    /// The editor promoted a number the person typed (or dictated) into a token on its own.
    func scoreLiteralPromoted(wasDictated: Bool) -> AnalyticsEvent {
        EntryEvents.scoreTokenCreated(source: wasDictated ? .dictation : .typed)
    }

    /// Tapping an existing token reopens the thing that made it.
    func reopen(_ token: EntryToken) -> Bool {
        guard let rating = token.score else { return false }
        scoring = Scoring(id: token.id, dishName: dishName(before: token.id), rating: rating)
        return true
    }

    func commitScore(_ rating: Rating, for tokenID: UUID) {
        composition = composition.replacing(tokenID: tokenID, with: .score(rating))
        revision += 1
        caretAfterRender = nil
        withAnimation(.snappy(duration: 0.2)) { scoring = nil }
        focusRequest += 1
    }

    func dismissScoring() {
        scoring = nil
        focusRequest += 1
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

    /// Design rule 8: a place is attached because it was **named or tapped**, never from location.
    ///
    /// A place already in the words is replaced where it stands. A new one lands **at the caret**,
    /// like the score token does — dropping it at index 0 shoved it in front of a sentence somebody
    /// was in the middle of writing. The one exception is a caret still at the start of text that
    /// already has words in it, which means the editor has not been touched yet; there the place
    /// goes at the end, where they are writing.
    func attach(place: PlaceRef) -> AnalyticsEvent {
        restaurantID = place.id
        if let existing = composition.spans.first(where: { $0.token.place != nil }) {
            composition = composition.replacing(tokenID: existing.token.id, with: .place(place))
            revision += 1
            caretAfterRender = nil
        } else {
            let end = composition.displayString.utf16.count
            let offset = (caret == 0 && end > 0) ? end : min(caret, end)
            let (next, newCaret) = composition.inserting(EntryToken(kind: .place(place)), atDisplayOffset: offset)
            apply(next, caret: newCaret)
        }
        isPickingPlace = false
        focusRequest += 1
        persist()
        return EntryEvents.placeAttached(source: .picked)
    }

    /// The place the words carry, if any — and therefore the `restaurant_id` the entry is written
    /// with. A `nil` id means the person named somewhere we do not hold yet: the words keep the
    /// name, the entry is written placeless, and the sorter parks its plan.
    var place: PlaceRef? { composition.place }

    /// What the place sheet opens pre-filled with: the words, never a location. The place already in
    /// the sentence if there is one, otherwise nothing — guessing from the prose is the sorter's job.
    var placeQuery: String { composition.place?.name ?? "" }

    // MARK: - Typing a number and moving on

    /// Done, and the keyboard's own path: anything still sitting in the words as a bare number
    /// becomes a token, exactly as it would when they moved on by typing.
    @discardableResult
    func promotePendingScoreLiteral() -> AnalyticsEvent? {
        // `pendingScoreLiteral` refuses a span a token already covers. Without that, Done on
        // "tiramisu <pill>" re-found the pill's own digits, replaced it with a new token of the
        // same value, and reported a second `entry_score_token_created` for one score.
        guard let found = composition.pendingScoreLiteral(atDisplayOffset: caret) else { return nil }
        composition = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .score(found.rating)))
        revision += 1
        caretAfterRender = nil
        return EntryEvents.scoreTokenCreated(source: .typed)
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
        guard let span = composition.spans.first(where: { $0.token.id == tokenID }) else { return "This dish" }
        let units = Array(composition.plain.utf16)
        let prefix = String(decoding: units[0..<min(span.span.location, units.count)], as: UTF16.self)
        let words = prefix
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .suffix(3)
            .joined(separator: " ")
        return words.isEmpty ? "This dish" : words
    }
}
