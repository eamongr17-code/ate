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

        if let place = card.place, let span = placeSpan(for: place, in: card, body: body) {
            // The pill is labelled with the BODY'S spelling, not the catalogue's: it stands in front
            // of the words it covers, and "tipo 00" is what they wrote (design rule 9). The id still
            // comes from the row, so tapping it opens the right place.
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: .place(PlaceRef(id: place.id, name: body.text(in: span)))),
                span: span
            ))
            claimed.append(span)
        }

        for item in card.items {
            guard let score = item.score else { continue }
            guard let span = scoreSpan(for: item, score: score, in: card, body: body, claimed: claimed) else {
                continue
            }
            spans.append(EntryTokenSpan(token: EntryToken(kind: .score(score)), span: span))
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
