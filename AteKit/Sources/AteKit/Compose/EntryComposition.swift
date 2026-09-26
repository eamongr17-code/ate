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

    /// A **legacy** place token, if these words still carry one (a draft saved before the place
    /// moved to the Place key). Read only by ``strippingPlaceTokens()``'s callers.
    public var place: PlaceRef? { spans.compactMap(\.token.place).first }

    public var scores: [Rating] { spans.compactMap(\.token.score) }

    public var tags: [DietTag] { spans.compactMap(\.token.tag) }

    /// **The migration off inline place tokens** (ComposerPlaceB, 2026-09-26).
    ///
    /// The place lives in the composer's Place key now, never in the words. A composition that still
    /// holds a place pill — a draft written before — keeps **every character** (design rule 9: the
    /// name the person typed stays in their sentence, as plain text) and loses only the pill. The
    /// place it pointed at is handed back so the caller can keep it on the entry.
    public func strippingPlaceTokens() -> (composition: EntryComposition, place: PlaceRef?) {
        guard let place else { return (self, nil) }
        return (
            EntryComposition(plain: plain, spans: spans.filter { $0.token.place == nil }),
            place
        )
    }

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

    /// The number the person has just finished typing at `offset`, **if it is not already a token**.
    ///
    /// The guard is the whole point. A score token's plain text is digits ("4.5"), so walking back
    /// from the caret finds them again — and the composer used to "promote" a pill the Score key had
    /// just put there into a second, identical pill with a new id, firing
    /// `entry_score_token_created(source: "typed")` for a score nobody typed. Score key, slide,
    /// Done: two events, one score.
    ///
    /// Both promotion paths — the editor's move-on check and Done — go through here, so neither can
    /// forget.
    public func pendingScoreLiteral(atDisplayOffset offset: Int) -> (span: TextSpan, rating: Rating)? {
        let plainCaret = plainOffset(forDisplayOffset: offset)
        guard let found = ScoreLiteral.candidate(in: plain, caretUTF16: plainCaret) else { return nil }
        guard spans.contains(where: { $0.span.intersects(found.span) }) == false else { return nil }
        return found
    }

    /// The dietary code the person has just finished typing at `offset` — "tiramisu v" — **if it is
    /// not already a token**. The same guard, for the same reason, as ``pendingScoreLiteral(atDisplayOffset:)``.
    public func pendingTagLiteral(atDisplayOffset offset: Int) -> (span: TextSpan, mark: DietTagMark)? {
        let plainCaret = plainOffset(forDisplayOffset: offset)
        guard let found = DietTagLiteral.candidate(in: plain, caretUTF16: plainCaret) else { return nil }
        guard spans.contains(where: { $0.span.intersects(found.span) }) == false else { return nil }
        return found
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
    public func applyingDisplayEdit(
        replacing range: TextSpan,
        with replacement: String
    ) -> (EntryComposition, caret: Int) {
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

    /// Inserts a token at a display offset — the Score / Place key.
    ///
    /// **A token is a word, and it brings its own gaps.** One space on each side where a word
    /// boundary is missing, none where one already exists, so that stripping the tokens still leaves
    /// a sentence: a place dropped in front of "with Jess" must not print as "Tipo 00with Jess".
    ///
    /// Two things this gets right that the first version did not, both from the CEO's first real
    /// entry — `PJ’s Mexican cantinafishbowl margarita  was a 4.5 and elitee`:
    ///
    /// 1. **The end of the text is not a boundary.** It used to be read as one (a missing character
    ///    was treated as a space), so a token inserted where the words end got no trailing gap — and
    ///    the next thing typed came out welded to it: "PJ’s Mexican cantinafishbowl". There is
    ///    nothing there yet; the token has to bring the space itself.
    /// 2. **The caret goes after everything the insertion added**, not between the token and its
    ///    trailing space. Landing it inside the inserted run leaves that space in front of the
    ///    caret, where every keystroke shoves it one place further along — the gap that belonged to
    ///    the pill ends up several words downstream, which is the double space before "was".
    public func inserting(
        _ token: EntryToken,
        atDisplayOffset offset: Int
    ) -> (EntryComposition, caret: Int) {
        let plainOffset = self.plainOffset(forDisplayOffset: offset)
        let units = Array(plain.utf16)
        // The start of the text is a boundary; so is whitespace already there. Nothing else is.
        let prefix = plainOffset == 0 || Self.whitespace.contains(units[plainOffset - 1]) ? "" : " "
        // After the token: whitespace, or the punctuation a word may touch — "the tiramisu 3.0,"
        // never "the tiramisu 3.0 ,". The end of the text is NOT a boundary (see 1 above).
        let suffix = plainOffset < units.count && Self.follows.contains(units[plainOffset]) ? "" : " "
        let inserted = prefix + token.plainText + suffix

        var next = applyingPlainEdit(replacing: TextSpan(location: plainOffset, length: 0), with: inserted)
        let span = TextSpan(location: plainOffset + prefix.utf16.count, length: token.plainText.utf16.count)
        next = EntryComposition(plain: next.plain, spans: next.spans + [EntryTokenSpan(token: token, span: span)])
        return (next, caret: next.displayOffset(forPlainOffset: span.endLocation + suffix.utf16.count))
    }

    private static let whitespace: Set<UInt16> = [32, 9, 10]
    /// What a word can be followed by with no gap in between: whitespace, and closing punctuation.
    private static let follows: Set<UInt16> = whitespace.union([
        44, 46, 33, 63, 59, 58, // , . ! ? ; :
        41, 93, 125, // ) ] }
        34, 39, 8221, 8217, // " ' ” ’
        8230 // …
    ])

    /// Re-scores (or renames) an existing token in place — tapping a token and sliding again.
    public func replacing(tokenID: UUID, with kind: EntryTokenKind) -> EntryComposition {
        guard let existing = spans.first(where: { $0.token.id == tokenID }) else { return self }
        // The token keeps its identity and whatever it points at — only what it says changes.
        var token = existing.token
        token.kind = kind
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
