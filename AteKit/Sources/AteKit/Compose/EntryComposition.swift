import Foundation

/// **The composer's model.** The person's words as one plain string, plus the tokens that live inline
/// in them as structured data alongside (design rule 9: the words are saved instantly and never
/// rewritten — the sorter only adds structure).
///
/// Two coordinate spaces, and keeping them straight is the whole job:
///
/// - **plain** — what is saved and shared. A score token occupies the characters `4.5`; a place token
///   occupies the place's name. Strip the tokens and you still have a sentence.
/// - **display** — what the text view holds. Each token collapses to ONE character (`U+FFFC`, the
///   object-replacement character) carrying an attachment that draws the pill. One character is what
///   makes a token behave like a single unit: backspace removes it whole, the caret can never land
///   inside it, and a selection can't cut it in half.
///
/// Every mutation is a pure function returning a new value, so the round-trip
/// (`display edit → plain + spans → display`) is unit-testable without a text view.
public struct EntryComposition: Hashable, Codable, Sendable {
    /// The object-replacement character a token collapses to in the display text.
    public static let tokenPlaceholder: Character = "\u{FFFC}"

    /// The words, verbatim.
    public private(set) var plain: String
    /// The tokens, sorted by location and never overlapping.
    public private(set) var spans: [EntryTokenSpan]

    public init() {
        self.plain = ""
        self.spans = []
    }

    /// Builds a composition, dropping any span that does not actually cover its token's text — the
    /// model refuses to hold a span that lies about the words, because everything downstream (the
    /// receipt's line items, the share image) reads the spans as truth.
    public init(plain: String, spans: [EntryTokenSpan]) {
        self.plain = plain
        let units = Array(plain.utf16)
        self.spans = spans
            .filter { span in
                guard span.span.location >= 0, span.span.endLocation <= units.count, span.span.length > 0 else {
                    return false
                }
                let slice = String(decoding: units[span.span.location..<span.span.endLocation], as: UTF16.self)
                return slice == span.token.plainText
            }
            .sorted { $0.span.location < $1.span.location }
    }

    // MARK: - Reading

    public var isEmpty: Bool { plain.isEmpty }

    /// The place the person attached, if any. Design rule 8: a place is only ever attached because
    /// they named it or tapped it, so this reads the token and nothing else — never a location.
    public var place: PlaceRef? { spans.compactMap(\.token.place).first }

    public var scores: [Rating] { spans.compactMap(\.token.score) }

    /// The display string: every token collapsed to one placeholder character.
    public var displayString: String {
        var units = Array(plain.utf16)
        for span in spans.reversed() {
            units.replaceSubrange(
                span.span.location..<span.span.endLocation,
                with: Array(String(Self.tokenPlaceholder).utf16)
            )
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Where each token sits in the display string, in order. Length is always 1.
    public var displaySpans: [EntryTokenSpan] {
        var shift = 0
        return spans.map { span in
            let location = span.span.location - shift
            shift += span.span.length - 1
            return EntryTokenSpan(token: span.token, span: TextSpan(location: location, length: 1))
        }
    }

    /// The token at a display offset, for "tap a token to reopen it".
    public func token(atDisplayOffset offset: Int) -> EntryToken? {
        displaySpans.first { $0.span.contains(offset) }?.token
    }

    // MARK: - Coordinates

    /// display → plain. A display offset inside no token maps straight through; an offset that lands
    /// on a token's placeholder maps to the START of the token's plain text, and the offset just
    /// after it maps to the end.
    public func plainOffset(forDisplayOffset offset: Int) -> Int {
        var shift = 0
        for span in displaySpans {
            if offset <= span.span.location { break }
            shift += span.token.plainText.utf16.count - 1
        }
        return offset + shift
    }

    /// display → plain, for a whole range. A range that touches a token always swallows it whole,
    /// which is exactly why a token deletes as one unit.
    public func plainSpan(forDisplaySpan span: TextSpan) -> TextSpan {
        let start = plainOffset(forDisplayOffset: span.location)
        let end = plainOffset(forDisplayOffset: span.endLocation)
        return TextSpan(location: start, length: end - start)
    }

    /// plain → display. An offset that lands *inside* a token's characters clamps to the token's
    /// placeholder — there is no such caret position in display space.
    public func displayOffset(forPlainOffset offset: Int) -> Int {
        var result = offset
        for span in spans {
            if span.span.endLocation <= offset {
                result -= span.span.length - 1
            } else if span.span.location < offset {
                result -= offset - span.span.location
            } else {
                break
            }
        }
        return result
    }

    // MARK: - Editing

    /// Applies an edit expressed in **display** coordinates — which is how a text view reports one —
    /// and returns the new composition plus where the caret should land, in display coordinates.
    ///
    /// Tokens the edit touches are removed (their plain characters go with them). Tokens after the
    /// edit shift by the length delta. Nothing is ever partially deleted.
    public func applyingDisplayEdit(replacing range: TextSpan, with replacement: String) -> (EntryComposition, caret: Int) {
        let plainRange = plainSpan(forDisplaySpan: range)
        let next = applyingPlainEdit(replacing: plainRange, with: replacement)
        let caretPlain = plainRange.location + replacement.utf16.count
        return (next, caret: next.displayOffset(forPlainOffset: caretPlain))
    }

    /// The same edit in plain coordinates. Used by tests and by anything that already knows where it
    /// is in the words (the score-literal promotion, a paste).
    public func applyingPlainEdit(replacing range: TextSpan, with replacement: String) -> EntryComposition {
        var units = Array(plain.utf16)
        let clamped = TextSpan(
            location: min(max(0, range.location), units.count),
            length: min(range.length, max(0, units.count - min(max(0, range.location), units.count)))
        )
        units.replaceSubrange(clamped.location..<clamped.endLocation, with: Array(replacement.utf16))
        let delta = replacement.utf16.count - clamped.length

        let survivors: [EntryTokenSpan] = spans.compactMap { span in
            if span.span.endLocation <= clamped.location { return span }
            if span.span.location >= clamped.endLocation {
                var moved = span
                moved.span.location += delta
                return moved
            }
            return nil // touched by the edit: the token goes, whole.
        }

        return EntryComposition(plain: String(decoding: units, as: UTF16.self), spans: survivors)
    }

    /// Turns characters that are already in the words into a token — the "typed `, 4.5` and moved on"
    /// path. The words do not change; only structure is added.
    public func promoting(plainSpan range: TextSpan, to token: EntryToken) -> EntryComposition {
        let units = Array(plain.utf16)
        guard range.location >= 0, range.endLocation <= units.count, range.length > 0 else { return self }
        // Promotion may rewrite `4` as `4.0`: a score prints like a price, always one decimal.
        let replaced = applyingPlainEdit(replacing: range, with: token.plainText)
        let span = TextSpan(location: range.location, length: token.plainText.utf16.count)
        return EntryComposition(
            plain: replaced.plain,
            spans: (replaced.spans + [EntryTokenSpan(token: token, span: span)])
        )
    }

    /// Inserts a token at a display offset — the Score / Place key. Adds a leading space when the
    /// caret is tight against a word, so the words stay readable when the tokens are stripped.
    public func inserting(
        _ token: EntryToken,
        atDisplayOffset offset: Int
    ) -> (EntryComposition, caret: Int) {
        let plainOffset = self.plainOffset(forDisplayOffset: offset)
        let units = Array(plain.utf16)
        let previous = plainOffset > 0 ? units[plainOffset - 1] : UInt16(32)
        let needsSpace = previous != 32 && previous != 10 && previous != 9
        let prefix = needsSpace ? " " : ""
        let inserted = prefix + token.plainText

        var next = applyingPlainEdit(replacing: TextSpan(location: plainOffset, length: 0), with: inserted)
        let span = TextSpan(location: plainOffset + prefix.utf16.count, length: token.plainText.utf16.count)
        next = EntryComposition(plain: next.plain, spans: next.spans + [EntryTokenSpan(token: token, span: span)])
        return (next, caret: next.displayOffset(forPlainOffset: span.endLocation))
    }

    /// Re-scores (or renames) an existing token in place — tapping a token and sliding again.
    public func replacing(tokenID: UUID, with kind: EntryTokenKind) -> EntryComposition {
        guard let existing = spans.first(where: { $0.token.id == tokenID }) else { return self }
        let token = EntryToken(id: tokenID, kind: kind)
        let stripped = applyingPlainEdit(replacing: existing.span, with: token.plainText)
        let span = TextSpan(location: existing.span.location, length: token.plainText.utf16.count)
        return EntryComposition(
            plain: stripped.plain,
            spans: stripped.spans + [EntryTokenSpan(token: token, span: span)]
        )
    }

    /// Removes a token and the characters it occupied.
    public func removing(tokenID: UUID) -> EntryComposition {
        guard let existing = spans.first(where: { $0.token.id == tokenID }) else { return self }
        return applyingPlainEdit(replacing: existing.span, with: "")
    }

    /// The plain text of a display range — what `copy` must put on the pasteboard, so pasting a
    /// score into Messages yields "4.5" and not an empty box.
    public func plainText(inDisplaySpan span: TextSpan) -> String {
        let range = plainSpan(forDisplaySpan: span)
        let units = Array(plain.utf16)
        guard range.location >= 0, range.endLocation <= units.count else { return "" }
        return String(decoding: units[range.location..<range.endLocation], as: UTF16.self)
    }
}
