import Foundation

/// **Putting the tokens back into a saved entry's words.**
///
/// The entry page and the journal slip both show the person's body text with its score and place
/// pills in it. The scores come from the **receipt lines** — the server already decided which
/// numbers in the body were scores — so this only has to find *where* each one sits.
///
/// Finding is the hard part, and it is why this lives in AteKit with tests rather than in a view.
/// A body reads "Paid $14.50 for the pasta … a clear 4.5 out of 5", and a naive substring search
/// puts the 4.5 pill inside the price. Two rules keep it honest:
///
/// 1. **Word boundaries.** An occurrence preceded by a digit, `$`, `.` or `,`, or followed by a
///    digit, is part of a longer number and is never the score.
/// 2. **Proximity.** When several occurrences survive, the one nearest where the dish is named wins
///    — the score the sorter recorded for the tagliatelle is the one written next to it.
///
/// Both are a stand-in. The contract has no offsets yet; when `entry_cards.items[]` carries the
/// evidence offset the server already computed, this becomes a lookup and the guessing stops.
public enum EntryBodyTokens {

    public static func composition(for card: EntryCard) -> EntryComposition {
        let units = Array(card.body.utf16)
        var spans: [EntryTokenSpan] = []
        /// Ranges already spoken for, so two items with the same score never claim one occurrence.
        var claimed: [TextSpan] = []

        if let place = card.place,
           let span = occurrences(of: place.name, in: units).first(where: { isFree($0, claimed) }) {
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: .place(PlaceRef(id: place.id, name: place.name))),
                span: span
            ))
            claimed.append(span)
        }

        for item in card.items {
            guard let score = item.score else { continue }
            let anchor = occurrences(of: item.dishName, in: units).first?.location
            guard let span = scoreSpan(
                literal: ScoreFormat.halfStep(score.value),
                in: units,
                nearest: anchor,
                claimed: claimed
            ) else { continue }
            spans.append(EntryTokenSpan(token: EntryToken(kind: .score(score)), span: span))
            claimed.append(span)
        }

        // `EntryComposition`'s own initialiser drops any span whose slice is not the token's text,
        // so a mismatch here costs one missing pill rather than a lie about somebody's words.
        return EntryComposition(plain: card.body, spans: spans)
    }

    // MARK: - Finding

    private static func scoreSpan(
        literal: String,
        in units: [UInt16],
        nearest anchor: Int?,
        claimed: [TextSpan]
    ) -> TextSpan? {
        let candidates = occurrences(of: literal, in: units)
            .filter { isFree($0, claimed) && isWholeNumber($0, in: units) }
        guard let anchor else { return candidates.first }
        return candidates.min { abs($0.location - anchor) < abs($1.location - anchor) }
    }

    /// Every occurrence of `needle`, in UTF-16 offsets. Case-insensitive on the ASCII range only:
    /// the sorter may have resolved "salmon roll" to the menu's "Salmon roll", and a pill that fails
    /// to appear because of one capital is worse than one found by a loose match.
    private static func occurrences(of needle: String, in units: [UInt16]) -> [TextSpan] {
        let target = Array(needle.utf16).map(lowercased)
        guard target.isEmpty == false, target.count <= units.count else { return [] }
        var found: [TextSpan] = []
        for start in 0...(units.count - target.count)
        where (0..<target.count).allSatisfy({ lowercased(units[start + $0]) == target[$0] }) {
            found.append(TextSpan(location: start, length: target.count))
        }
        return found
    }

    /// Rule 1: the occurrence is the whole number, not a slice of a longer one.
    private static func isWholeNumber(_ span: TextSpan, in units: [UInt16]) -> Bool {
        if span.location > 0 {
            let before = units[span.location - 1]
            // digit, `$`, `.` or `,` — "$14.50", "3.4.5", "1,4.5"
            if isDigit(before) || before == 36 || before == 46 || before == 44 { return false }
        }
        if span.endLocation < units.count, isDigit(units[span.endLocation]) { return false }
        return true
    }

    private static func isFree(_ span: TextSpan, _ claimed: [TextSpan]) -> Bool {
        claimed.contains { $0.intersects(span) } == false
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    /// ASCII lowercasing. Enough for a dish name's capital, and it cannot mis-fold anything outside
    /// A–Z (a Turkish `İ` is left exactly as it is).
    private static func lowercased(_ unit: UInt16) -> UInt16 {
        (unit >= 65 && unit <= 90) ? unit + 32 : unit
    }
}
