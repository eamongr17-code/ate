import Foundation

/// **Putting the tokens back into a saved entry's words.**
///
/// The entry page and the journal slip both show the person's body text with its score and place
/// pills in it. WHERE each one sits is the server's answer, not ours: `entry_cards` carries
/// `place_offset`/`place_length`, and every receipt line carries `evidence_offset`/`evidence_length`
/// (the score) and `mention_offset`/`mention_length` (the dish) — 0-based **Unicode scalar** offsets
/// into `body`, each one verified against the body by the database on the way in (`verified_offset`,
/// migration 0024).
///
/// So this is a lookup, and the searching it used to do is only the fallback. The difference is not
/// academic: `"Paid $14.50 for the pasta … a clear 4.5"` contains `4.5` twice and the price is FIRST,
/// which is how a pill ends up inside somebody's bill total.
///
/// Four rules, in order:
///
/// 1. **Offsets win.** Nothing is searched for while the server can point at it.
/// 2. **A score pill covers the number, not the phrase.** `evidence_offset` points at
///    `score_evidence`, which holds the number but may be longer than it ("4.5 stars", "4 out of 5").
///    The pill goes on the digits *inside* that window, so it can never swallow a word — and because
///    the window came from the server, the digits it finds are the ones that line was scored from.
/// 3. **Offsets are verified, never trusted.** They describe the body *as it was sorted*; a body
///    edited since (`updated_at > sorted_at`) may have moved everything. The score's digits must
///    still be in the window, and a stale place window must still name the place. Otherwise: rule 4.
/// 4. **No usable offset ⇒ the matcher**, with the two rules it always had — word boundaries (an
///    occurrence touching a digit, `$`, `.` or `,` is part of a longer number) and proximity (of
///    several honest occurrences, the one nearest where the dish is named wins).
///
/// What is never done is inventing: ``EntryComposition``'s own initialiser drops any span whose slice
/// is not the token's text, so the worst case here is one missing pill rather than a lie about
/// somebody's words.
public enum EntryBodyTokens {

    public static func composition(for card: EntryCard) -> EntryComposition {
        let body = BodyOffsets(card.body)
        var spans: [EntryTokenSpan] = []
        /// Ranges already spoken for, so two lines with the same score never claim one occurrence.
        var claimed: [TextSpan] = []

        // **No place pill** (ComposerPlaceB, 2026-09-26). The place lives on the entry, never in the
        // words: an entry written when the composer still put it there shows the name as the plain
        // text it always was, and keeps its place. The span is still claimed, so a dish or a number
        // inside the place's name ("Tipo 00") can never be mistaken for a line of the bill.
        if let place = card.place, let span = placeSpan(for: place, in: card, body: body) {
            claimed.append(span)
        }

        let mentions = card.items.compactMap { mention(of: $0, in: body) }
        for item in card.items {
            for span in tagSpans(for: item, in: body, mentions: mentions, claimed: claimed) {
                spans.append(span)
                claimed.append(span.span)
            }
        }

        for item in card.items {
            guard let score = item.score else { continue }
            guard let span = scoreSpan(for: item, score: score, in: card, body: body, claimed: claimed) else {
                continue
            }
            spans.append(EntryTokenSpan(token: EntryToken(kind: .score(score), dishID: item.dishID), span: span))
            claimed.append(span)
        }

        return EntryComposition(plain: card.body, spans: spans)
    }

    // MARK: - Where the place is

    private static func placeSpan(
        for place: EntryCard.Place,
        in card: EntryCard,
        body: BodyOffsets
    ) -> TextSpan? {
        if let window = body.span(scalarOffset: card.placeOffset, scalarLength: card.placeLength) {
            // Fresh offsets are the server's verified answer and are taken as they are — `place_query`
            // is the phrase that matched, which can legitimately differ from the catalogue name.
            // A stale one has to prove itself, and the only proof available on this side is that the
            // words there still name this place.
            if offsetsAreFresh(card) || body.text(in: window).lowercased() == place.name.lowercased() {
                return window
            }
        }
        // The matcher. Case-insensitive, so the pill survives a capital the person did not type.
        return body.occurrences(of: place.name).first
    }

    // MARK: - Where the tags are

    /// A line's dietary chips: the codes the sorter read, found where the sorter found them.
    ///
    /// The sorter attaches a chip to **the dish named nearest before it** (`sort-entry/tags.ts`,
    /// `attachTagTokens`) — which is also the Diet key's rule: a chip belongs to the nearest dish to
    /// its left. So a line's chips are looked for in its **stretch**: from the end of its mention to
    /// the next line's mention. Two ways in, both biased hard toward leaving words alone:
    ///
    /// - **straight after the mention** ("tiramisu v 3.0"), any case — the typed chip's only place;
    /// - **anywhere later in the stretch**, but only in the chip's own capitals ("the salmon roll 4.5
    ///   was great, GF") — the Diet key's chip wherever the caret was. Lower case that far from the
    ///   dish is prose ("it was v good"), and stays prose.
    ///
    /// Without a mention there is nothing honest to anchor on, so no chip is drawn (the dish row still
    /// carries the tag).
    private static func tagSpans(
        for item: EntryCard.Item,
        in body: BodyOffsets,
        mentions: [TextSpan],
        claimed: [TextSpan]
    ) -> [EntryTokenSpan] {
        guard item.tags.isEmpty == false, let mention = mention(of: item, in: body) else { return [] }
        let units = body.units
        let stretchEnd = mentions
            .map(\.location)
            .filter { $0 >= mention.endLocation }
            .min() ?? units.count
        var remaining = Set(item.tags)
        var spans: [EntryTokenSpan] = []

        func claim(_ start: Int, _ end: Int, text: String) {
            guard let tag = DietTag(code: text), remaining.contains(tag) else { return }
            let span = TextSpan(location: start, length: end - start)
            guard isFree(span, claimed), isFree(span, spans.map(\.span)) else { return }
            // The chip carries its line's dish, so an edit that deletes it can clear that line's
            // tag (``EditTagDiff``) instead of forcing a re-sort.
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: .tag(DietTagMark(tag: tag, text: text)), dishID: item.dishID), span: span
            ))
            remaining.remove(tag)
        }

        // Straight after the dish, one word after another: "tiramisu V GF 3.0".
        var cursor = mention.endLocation
        while remaining.isEmpty == false {
            var start = cursor
            while start < stretchEnd, units[start] == 32 { start += 1 }
            guard start > cursor else { break }
            var end = start
            while end < stretchEnd, isASCIILetter(units[end]) { end += 1 }
            guard end > start, end == stretchEnd || isWordBoundary(units[end]) else { break }
            let text = String(decoding: units[start..<end], as: UTF16.self)
            let before = spans.count
            claim(start, end, text: text)
            guard spans.count > before else { break }
            cursor = end
        }

        // Later in the stretch: whole words in the chip's own capitals.
        for code in capitalCodes(in: units, from: cursor, to: stretchEnd) where remaining.isEmpty == false {
            claim(code.span.location, code.span.endLocation, text: code.text)
        }
        return spans.sorted { $0.span.location < $1.span.location }
    }

    /// Whole words between `start` and `end` written as a chip prints them: "GF", "VG", "V".
    private static func capitalCodes(
        in units: [UInt16], from start: Int, to end: Int
    ) -> [(span: TextSpan, text: String)] {
        var found: [(span: TextSpan, text: String)] = []
        var index = start
        while index < end {
            guard isASCIILetter(units[index]), index == 0 || isWordBoundary(units[index - 1]) else {
                index += 1
                continue
            }
            var wordEnd = index
            while wordEnd < end, isASCIILetter(units[wordEnd]) { wordEnd += 1 }
            let text = String(decoding: units[index..<wordEnd], as: UTF16.self)
            let isWhole = wordEnd == units.count || isWordBoundary(units[wordEnd])
            if isWhole, let tag = DietTag(code: text), text == tag.label {
                found.append((TextSpan(location: index, length: wordEnd - index), text))
            }
            index = wordEnd
        }
        return found
    }

    private static func mention(of item: EntryCard.Item, in body: BodyOffsets) -> TextSpan? {
        body.span(scalarOffset: item.mentionOffset, scalarLength: item.mentionLength)
            ?? body.occurrences(of: item.dishName).first
    }

    /// Not a letter or a digit: "GFX" and "GF2" are not chips.
    private static func isWordBoundary(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) == false
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    // MARK: - Where the score is

    private static func scoreSpan(
        for item: EntryCard.Item,
        score: Rating,
        in card: EntryCard,
        body: BodyOffsets,
        claimed: [TextSpan]
    ) -> TextSpan? {
        let literal = ScoreFormat.halfStep(score.value)

        // 1. The server's window, with the digits located inside it. Finding them there IS the
        //    staleness test the contract names ("the sure test is that the slice still holds the
        //    score's digits"), so a fresh and a stale offset are checked the same way and neither can
        //    put a pill on text that is no longer a number.
        if let window = body.span(scalarOffset: item.evidenceOffset, scalarLength: item.evidenceLength),
           let digits = honestOccurrences(of: literal, in: body, within: window, claimed: claimed).first {
            return digits
        }

        // 2. Nothing to point at: match, anchored on the dish's mention when the server pointed at
        //    THAT (the same hint, one field over) and on a search for the dish name when it did not.
        let candidates = honestOccurrences(of: literal, in: body, within: nil, claimed: claimed)
        let anchor = body.span(scalarOffset: item.mentionOffset, scalarLength: item.mentionLength)?.location
            ?? body.occurrences(of: item.dishName).first?.location
        guard let anchor else { return candidates.first }
        return candidates.min { abs($0.location - anchor) < abs($1.location - anchor) }
    }

    /// Occurrences that are a whole number and not already claimed by another line.
    private static func honestOccurrences(
        of literal: String,
        in body: BodyOffsets,
        within window: TextSpan?,
        claimed: [TextSpan]
    ) -> [TextSpan] {
        body.occurrences(of: literal, within: window)
            .filter { body.isWholeNumber($0) && isFree($0, claimed) }
    }

    /// Whether the offsets still describe the body in front of us.
    ///
    /// `updated_at > sorted_at` is the contract's hint that the words were edited after the sort. An
    /// entry that has never been sorted has no offsets worth the name either.
    private static func offsetsAreFresh(_ card: EntryCard) -> Bool {
        guard let sortedAt = card.sortedAt else { return false }
        return card.updatedAt <= sortedAt
    }

    private static func isFree(_ span: TextSpan, _ claimed: [TextSpan]) -> Bool {
        claimed.contains { $0.intersects(span) } == false
    }
}
