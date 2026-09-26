import Foundation

/// **A score said the way people say one** (round 4) — "four and a half", "four point five", "a
/// solid four", "4 out of 5" — after a dish, as the keyboard's dictation writes it or as it is
/// typed. Each becomes the same pill a typed `4.5` does.
///
/// The same bias as ``ScoreLiteral``, harder, because words are more ambiguous than digits: "we
/// were four", "four of us", "one more" are not scores. So a number *word* only becomes a score in
/// a shape that cannot mean anything else:
///
/// - with its half spelled out — `four and a half`, `four point five`, `4 1/2`, `4½`;
/// - out of five — `four out of five`, `4 out of 5`, `4.5 out of 5`;
/// - or after an article and at most one word of judgement — `a four`, `a solid four`,
///   `an easy five` (``judgements``).
///
/// A bare typed digit is ``ScoreLiteral``'s, not this. And the secret 6 is never a phrase: "six out
/// of five" is prose (round 4 contract — a 6 is only ever marked on the slider).
///
/// The span returned covers the **whole phrase** — the words that said the score become its pill
/// (the Score token's plain text), everything around it is untouched. A phrase may begin at a score
/// pill already in the words (`<4.0> and a half`, typed after a `4` promoted at its space): the
/// caller replaces that pill with the new one.
public enum ScorePhrase {
    public static func candidate(in plain: String, caretUTF16 caret: Int) -> (span: TextSpan, rating: Rating)? {
        let units = Array(plain.utf16)
        guard caret > 0, caret <= units.count else { return nil }
        guard let end = ScoreLiteral.endIgnoringFullStop(units, caret: caret), end > 0 else { return nil }
        guard ScoreLiteral.isTerminated(units, at: end) else { return nil }

        let words = Self.words(before: end, in: units)
        guard words.isEmpty == false else { return nil }

        let half = halfSpelled(words).flatMap { match in
            // "we waited four and a half" is a duration, not a score: a half-step said after a word
            // of quantity or time is left alone. (Out of five needs no such care — it says what it is.)
            match.first > 0 && quantityWords.contains(words[match.first - 1].text) ? nil : match
        }
        for match in [outOfFive(words), half, judged(words)] {
            guard let match, let rating = Rating(exactly: match.value),
                  rating <= .maximum else { continue }
            let start = words[match.first].range.location
            // A dish before it: the same test a typed number passes — words, not a symbol or a list.
            guard ScoreLiteral.hasWordsBefore(units, start: start) else { continue }
            return (TextSpan(location: start, length: end - start), rating)
        }
        return nil
    }

    // MARK: - Shapes

    private typealias Match = (first: Int, value: Double)

    /// `VALUE out of 5` / `VALUE out of five`.
    private static func outOfFive(_ words: [Word]) -> Match? {
        let count = words.count
        guard count >= 4, ["5", "five"].contains(words[count - 1].text),
              words[count - 2].text == "of", words[count - 3].text == "out" else { return nil }
        let head = Array(words[..<(count - 3)])
        if let half = halfSpelled(head) { return half }
        guard let last = head.last, let value = number(last.text, allowsDecimal: true) else { return nil }
        return (head.count - 1, value)
    }

    /// `N and a half`, `N point five`, `N point 5`, `N 1/2`, `N½`.
    private static func halfSpelled(_ words: [Word]) -> Match? {
        let count = words.count
        let texts = words.map(\.text)
        if count >= 4, Array(texts[(count - 3)...]) == ["and", "a", "half"],
           let whole = number(texts[count - 4], allowsDecimal: true), whole.rounded() == whole {
            return (count - 4, whole + 0.5)
        }
        if count >= 3, texts[count - 2] == "point", let whole = number(texts[count - 3], allowsDecimal: false) {
            switch texts[count - 1] {
            case "five", "5": return (count - 3, whole + 0.5)
            case "zero", "0", "oh", "o": return (count - 3, whole)
            default: return nil
            }
        }
        if count >= 2, ["1/2", "½"].contains(texts[count - 1]),
           let whole = number(texts[count - 2], allowsDecimal: false) {
            return (count - 2, whole + 0.5)
        }
        if let last = texts.last, last.hasSuffix("½"),
           let whole = number(String(last.dropLast()), allowsDecimal: false) {
            return (count - 1, whole + 0.5)
        }
        return nil
    }

    /// `a four`, `a solid four`: a number WORD after an article and at most one judgement.
    private static func judged(_ words: [Word]) -> Match? {
        let count = words.count
        guard count >= 2, let value = wordNumbers[words[count - 1].text] else { return nil }
        let before = words[count - 2].text
        if articles.contains(before) { return (count - 1, value) }
        if count >= 3, judgements.contains(before), articles.contains(words[count - 3].text) {
            return (count - 1, value)
        }
        return nil
    }

    // MARK: - Words

    private struct Word {
        let text: String
        let range: TextSpan
    }

    /// Up to eight whitespace-separated words ending at `end`, lowercased, oldest first.
    private static func words(before end: Int, in units: [UInt16]) -> [Word] {
        var result: [Word] = []
        var index = end
        while index > 0, result.count < 8 {
            while index > 0, isSpace(units[index - 1]) { index -= 1 }
            let wordEnd = index
            while index > 0, isSpace(units[index - 1]) == false { index -= 1 }
            guard index < wordEnd else { break }
            let text = String(decoding: units[index..<wordEnd], as: UTF16.self).lowercased()
            result.append(Word(text: text, range: TextSpan(location: index, length: wordEnd - index)))
        }
        return result.reversed()
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 160 }

    /// A whole number in words or digits — or, where a phrase allows it, the digits of a score pill
    /// already in the words (`4.0`).
    private static func number(_ text: String, allowsDecimal: Bool) -> Double? {
        if let word = wordNumbers[text] { return word }
        guard text.isEmpty == false, text.count <= 3,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(text) else { return nil }
        if allowsDecimal == false, text.contains(".") { return nil }
        return value
    }

    private static let wordNumbers: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5
    ]
    private static let articles: Set<String> = ["a", "an"]
    /// Words that make the number after them a quantity or a time.
    static let quantityWords: Set<String> = [
        "for", "about", "around", "after", "had", "of", "waited", "took", "than", "only", "nearly",
        "almost", "over", "under", "like", "maybe", "roughly", "at", "in", "ate", "ordered", "were", "us"
    ]
    /// The words people put between "a" and a score. Closed on purpose: an open slot would let "a
    /// party of four" through.
    static let judgements: Set<String> = [
        "solid", "strong", "easy", "clear", "good", "firm", "hard", "high", "low", "straight",
        "generous", "decent", "respectable", "honest", "fair", "big", "comfortable", "perfect",
        "weak", "soft", "tight", "safe", "definite", "clean", "full"
    ]
}
