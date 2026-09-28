import AteKit
import SwiftUI
import UIKit

/// **Promotion** — the coordinator's half that turns a number the person typed (or a diet mark) into
/// a pill once they have moved on from it. Out of `InlineTokenCoordinator.swift` so each file reads in
/// one sitting; the checks that call it are still there.
extension InlineTokenEditor.Coordinator {

    /// A number the person has moved on from: where it sits, and what it is worth.
    struct Promotion {
        /// The digits, in display offsets.
        let range: NSRange
        /// What they read — checked again before the pill goes in, so a promotion noticed a turn
        /// ago can never land on characters that have changed since.
        let literal: String
        let token: EntryToken
        /// Said in words ("four and a half") rather than typed as a number.
        var isPhrase = false
    }

    /// "Typing a number after a dish becomes a score token." Read-only: the condition is the
    /// character under the caret — a move-on straight after a digit.
    func promotableScore(in view: InlineTokenTextView) -> Promotion? {
        let caret = view.selectedRange
        guard caret.length == 0, caret.location > 0 else { return nil }
        let storage = view.textStorage
        let lastCharacter = storage.attributedSubstring(
            from: NSRange(location: caret.location - 1, length: 1)
        ).string
        // A `.` after a digit waits only while it could still be a decimal: after "4.5" it is the
        // sentence ending, and "it was a 4.5." promotes at it (round 4).
        guard ScoreLiteral.isMoveOn(lastCharacter, typedAt: caret.location - 1, in: storage.string) else {
            return nil
        }

        let model = composition(from: view)
        // Both finders refuse a span a token already covers, so a Score-key pill is never
        // "promoted" twice. A number becomes a score; "tiramisu v" a tag chip (`DietTagsB`).
        let offset = caret.location - 1
        let score = model.pendingScoreLiteral(atDisplayOffset: offset)
            .map { (span: $0.span, kind: EntryTokenKind.score($0.rating)) }
        let tag = model.pendingTagLiteral(atDisplayOffset: offset)
            .map { (span: $0.span, kind: EntryTokenKind.tag($0.mark)) }
        guard let found = score ?? tag else { return nil }

        let start = model.displayOffset(forPlainOffset: found.span.location)
        let end = model.displayOffset(forPlainOffset: found.span.endLocation)
        let range = NSRange(location: start, length: end - start)
        guard let literal = text(at: range, in: view) else { return nil }
        return Promotion(
            range: range, literal: literal, token: EntryToken(kind: found.kind),
            isPhrase: score != nil && model.isPhrase(found.span)
        )
    }

    /// Whether the words still say there what they said when this was noticed.
    func stillReads(_ promotion: Promotion, in view: InlineTokenTextView) -> Bool {
        text(at: promotion.range, in: view) == promotion.literal
    }

    func text(at range: NSRange, in view: InlineTokenTextView) -> String? {
        let storage = view.textStorage
        guard range.location >= 0, range.length > 0, range.upperBound <= storage.length else { return nil }
        return storage.attributedSubstring(from: range).string
    }

    /// The digits out, one pill in.
    func apply(_ promotion: Promotion, in view: InlineTokenTextView) {
        let caret = view.selectedRange.location
        let shift = 1 - promotion.range.length
        lastPromotedToken = promotion.token

        // One placeholder character in through the edit path, then its attachment as an
        // attribute. Undoing this restores the digits the person typed, which is what they
        // would expect and what UIKit's own operation now describes correctly.
        write(StorageEdit(
            text: String(EntryComposition.tokenPlaceholder),
            range: promotion.range,
            tokens: [EntryTokenSpan(
                token: promotion.token,
                span: TextSpan(location: promotion.range.location, length: 1)
            )],
            // The caret moves with the words only when it was after them. When the promotion is
            // landing behind a caret that has already typed on, where they are is where they stay.
            caret: caret >= promotion.range.upperBound ? caret + shift : caret,
            updatesBinding: true
        ), in: view)
        AteHaptics.tick()
        // `primaryLanguage == "dictation"` is how UIKit reports that the text arrived from the
        // keyboard's mic rather than its keys. It is the only signal there is, and being wrong
        // costs one mislabelled funnel event — never a word of anybody's entry.
        callbacks.onTokenPromoted(
            promotion.token, view.textInputMode?.primaryLanguage == "dictation", promotion.isPhrase
        )
    }
}
