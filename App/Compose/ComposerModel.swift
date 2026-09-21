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

    var composition: EntryComposition
    /// Bumped to force the editor to rebuild its storage after a programmatic change.
    private(set) var revision = 0
    /// Where the caret should land after that rebuild, in display offsets.
    private(set) var caretAfterRender: Int?
    /// Where the caret is now, as the editor reports it.
    var caret = 0
    var scoring: Scoring?
    /// Per entry, not per account (PRODUCT.md decision 1: public by default, any entry can be private).
    var isPublic = true
    /// Bumped to pull the keyboard back after the slider or a sheet closes.
    private(set) var focusRequest = 0

    init(composition: EntryComposition = EntryComposition()) {
        self.composition = composition
        self.caret = composition.displayString.utf16.count
    }

    /// True once there is anything worth saving. Photos-only entries are legal (`body` may be `''`),
    /// so the composer's own gate is "words or photos", not "words".
    var hasContent: Bool { composition.isEmpty == false }

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
        if let existing = composition.spans.first(where: { $0.token.place != nil }) {
            composition = composition.replacing(tokenID: existing.token.id, with: .place(place))
            revision += 1
            caretAfterRender = nil
        } else {
            let (next, newCaret) = composition.inserting(EntryToken(kind: .place(place)), atDisplayOffset: 0)
            apply(next, caret: newCaret)
        }
        focusRequest += 1
        return EntryEvents.placeAttached(source: .picked)
    }

    /// The place the words carry, if any — and therefore the `restaurant_id` the entry is written
    /// with. `nil` id means the person named somewhere we do not hold yet: the words keep the name,
    /// the entry stays placeless, and the sorter parks its plan.
    var place: PlaceRef? { composition.place }

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
