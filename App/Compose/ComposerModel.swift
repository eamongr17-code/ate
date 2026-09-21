import AteKit
import Observation
import SwiftUI

/// **The composer's state**, and every rule about how a token gets into the words.
///
/// The words themselves live in ``EntryComposition`` (AteKit, unit-tested); this holds what the
/// screen needs around them — where the caret is, which token the slider is open on, whether the
/// entry is public, which photos are attached — and nothing else. The view renders it and calls it.
@MainActor
@Observable
final class ComposerModel {
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
    /// Per entry, not per account (PRODUCT.md decision 1: public by default, any entry can be private).
    var isPublic = true {
        didSet { persist() }
    }
    /// Up to five, in the order they were picked.
    private(set) var photos: [StagedPhoto] = []
    /// Bumped to pull the keyboard back after the slider or a sheet closes.
    private(set) var focusRequest = 0
    var isPickingPlace = false

    /// The entry's id, minted here and carried to the INSERT — what makes the write idempotent.
    let draftID: UUID
    private let drafts: any EntryDraftStoring
    private let startedAt: Date
    private var restaurantID: UUID?

    init(drafts: any EntryDraftStoring) {
        self.drafts = drafts
        let resumed = drafts.load()
        self.draftID = resumed?.id ?? UUID()
        self.composition = resumed?.composition ?? EntryComposition()
        self.isPublic = resumed?.isPublic ?? true
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
            isPublic: isPublic,
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

    // MARK: - The Place key

    /// Design rule 8: a place is attached because it was **named or tapped**, never from location.
    /// If a place token is already there it is replaced in place; otherwise it goes at the very front,
    /// which is where the design puts it.
    func attach(place: PlaceRef) -> AnalyticsEvent {
        restaurantID = place.id
        if let existing = composition.spans.first(where: { $0.token.place != nil }) {
            composition = composition.replacing(tokenID: existing.token.id, with: .place(place))
            revision += 1
            caretAfterRender = nil
        } else {
            let (next, newCaret) = composition.inserting(EntryToken(kind: .place(place)), atDisplayOffset: 0)
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
        guard let found = ScoreLiteral.candidate(
            in: composition.plain,
            caretUTF16: composition.plainOffset(forDisplayOffset: caret)
        ) else { return nil }
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
