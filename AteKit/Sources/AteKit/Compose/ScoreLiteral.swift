import Foundation

/// **"Typing a number after a dish becomes a score token."** (design, composer toolbar note.)
///
/// The whole rule, as one pure function, because it is the part that can be *wrong* in ways a
/// screenshot never shows: a price, a year, a table number and a time of day all look like a score
/// until you read what is around them. Getting this wrong rewrites someone's words — which design
/// rule 9 forbids outright — so the bias is hard toward **not** converting.
public enum ScoreLiteral {
    /// The number the person just finished typing, immediately before `caret`, if it can only be a
    /// score. Returns the span of the digits themselves (never the comma or space that led into
    /// them) and the score it means.
    ///
    /// Accepts: `4`, `4.5`, `0.5`, `5`, and the same after a comma or a dash — the shapes in the
    /// design (`", 4.5"`, `" 4"`).
    ///
    /// Rejects: anything not a half step (`4.7`), out of range (`0`, `6`, `2026`), attached to a
    /// symbol or unit (`$4.5`, `4.5km`, `#4`, `12.5`), part of a longer number (`14`), a fraction
    /// already written out (`4.5/5` — the `/5` is the giveaway it is being quoted, not scored), and
    /// a bare number with no words before it (that is a list, not a review).
    public static func candidate(in plain: String, caretUTF16 caret: Int) -> (span: TextSpan, rating: Rating)? {
        let units = Array(plain.utf16)
        guard caret > 0, caret <= units.count else { return nil }

        // Walk back over digits and at most one decimal separator.
        var start = caret
        var dotCount = 0
        while start > 0 {
            let unit = units[start - 1]
            if isDigit(unit) {
                start -= 1
            } else if unit == dot, dotCount == 0, start - 1 > 0, isDigit(units[start - 2]) {
                dotCount += 1
                start -= 1
            } else {
                break
            }
        }
        guard start < caret else { return nil }

        let literal = String(decoding: units[start..<caret], as: UTF16.self)
        guard let rating = rating(for: literal) else { return nil }

        // What leads in: a space, a comma-space, a dash — never a symbol, digit or letter.
        guard hasWordsBefore(units, start: start) else { return nil }
        // What follows: nothing, or a boundary. A unit or a slash means it was never a score.
        guard isTerminated(units, at: caret) else { return nil }

        return (TextSpan(location: start, length: caret - start), rating)
    }

    /// The characters that mean "the person has moved on" — the moment a pending number becomes a
    /// token. Typing one of these, leaving the field, or tapping Done all count.
    public static func isMoveOn(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else {
            return text.isEmpty == false && text.allSatisfy { $0.isWhitespace }
        }
        return moveOnScalars.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Pieces

    private static let dot = UInt16(46) // .
    /// What may sit between the words and the number: space, tab, newline, comma, and the three
    /// dashes a phone keyboard can produce.
    private static let separators: Set<UInt16> = [32, 9, 10, 44, 45, 8211, 8212]
    private static let moveOnScalars = Set<Unicode.Scalar>(",.!?;:".unicodeScalars)

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    /// A half step in 0.5…5.0, written with at most one decimal place.
    private static func rating(for literal: String) -> Rating? {
        let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, whole.count <= 1 else { return nil }
        if parts.count == 2, parts[1].count != 1 { return nil }
        guard let value = Double(literal) else { return nil }
        guard value >= 0.5, value <= 5 else { return nil }
        guard (value * 2).truncatingRemainder(dividingBy: 1) == 0 else { return nil }
        return Rating(exactly: value)
    }

    /// There has to be a word before the number. A number at the very start of the text, or after a
    /// symbol, is not somebody scoring a dish.
    private static func hasWordsBefore(_ units: [UInt16], start: Int) -> Bool {
        var index = start
        var sawSeparator = false
        while index > 0 {
            let unit = units[index - 1]
            if separators.contains(unit) {
                sawSeparator = true
                index -= 1
            } else {
                break
            }
        }
        guard sawSeparator, index > 0 else { return false }
        // The character that ends the words must be a letter or a closing punctuation, not a symbol
        // ("$", "#", "x") and not another digit ("table 4 2" is not a score).
        let unit = units[index - 1]
        if isDigit(unit) { return false }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar)
            || CharacterSet(charactersIn: ")]\"'”’").contains(scalar)
    }

    /// Nothing may follow but a boundary. A letter after the number is a unit ("4.5km"); a slash is
    /// a fraction the person wrote out themselves.
    private static func isTerminated(_ units: [UInt16], at caret: Int) -> Bool {
        guard caret < units.count else { return true }
        let unit = units[caret]
        if isDigit(unit) { return false }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        if CharacterSet.letters.contains(scalar) { return false }
        return CharacterSet(charactersIn: "/\\%$*").contains(scalar) == false
    }
}
