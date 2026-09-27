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
/// - or, bare, straight after a scoring phrase — `was a four`, `gave it four`, `a solid four`,
///   `an easy five` (``scoringPhrases``, ``judgements``).
///
/// And a number word only ever straight after a scoring phrase or a dish — never after a word of
/// quantity, time or company (``quantityWords``): "four of us", "a table for four", "waited four
/// and a half" stay prose.
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

        for match in [outOfFive(words), halfSpelled(words), judged(words)] {
            guard let match, let rating = Rating(exactly: match.value),
                  rating <= .maximum else { continue }
            // **Conservative about words** (round 4): a number spelled out only counts straight after
            // a scoring phrase ("was a", "gave it", "solid") or straight after a dish — never after a
            // word of quantity, time or company ("four of us", "waited four and a half"). A bare
            // "four" needs the scoring phrase. Digits keep their own, older rule.
            let lead = leadIn(words, before: match.first)
            if wordNumbers[words[match.first].text] != nil {
                let bare = match.first == words.count - 1
                guard lead == .scoring || (bare == false && lead == .dish) else { continue }
            } else if lead == .count {
                continue
            }
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
    /// A bare number word — accepted only after a scoring phrase (``leadIn(_:before:)``).
    private static func judged(_ words: [Word]) -> Match? {
        guard words.count >= 2, let value = wordNumbers[words[words.count - 1].text] else { return nil }
        return (words.count - 1, value)
    }

    // MARK: - What comes before

    private enum LeadIn { case scoring, dish, count, none }

    /// What the words just before a phrase make of it: a scoring phrase ("was a", "gave it a",
    /// "a solid"), a dish (any other word — the end of a dish's name), or a count (a word of
    /// quantity, time or company). `none` at the start of the words.
    private static func leadIn(_ words: [Word], before index: Int) -> LeadIn {
        let before = words[..<index].map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
        guard let last = before.last else { return .none }
        if scoringPhrases.contains(where: { before.count >= $0.count && Array(before.suffix($0.count)) == $0 }) {
            return .scoring
        }
        if judgements.contains(last), before.count >= 2, articles.contains(before[before.count - 2]) { return .scoring }
        if quantityWords.contains(last) || articles.contains(last) { return .count }
        // A word that ends a sentence or a clause is not a dish's name either.
        if let raw = words[index - 1].text.last, ".!?;:".contains(raw) { return .count }
        return .dish
    }

    /// What people say right before a score.
    static let scoringPhrases: [[String]] = [
        ["was", "a"], ["was", "an"], ["is", "a"], ["is", "an"], ["solid"], ["a", "solid"],
        ["gave", "it"], ["gave", "it", "a"], ["give", "it"], ["give", "it", "a"],
        ["rated", "it"], ["rated", "it", "a"], ["rate", "it"], ["rate", "it", "a"], ["scored"], ["scored", "a"],
        ["easy"], ["strong"]
    ]

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
        "almost", "over", "under", "like", "maybe", "roughly", "at", "in", "ate", "ordered", "were", "us",
        "the", "with", "and", "we", "our", "my", "those", "these", "them", "they", "there", "table",
        "party", "people", "honestly", "just", "another", "all", "are", "is", "was", "be", "been"
    ]
    /// The words people put between "a" and a score. Closed on purpose: an open slot would let "a
    /// party of four" through.
    static let judgements: Set<String> = [
        "solid", "strong", "easy", "clear", "good", "firm", "hard", "high", "low", "straight",
        "generous", "decent", "respectable", "honest", "fair", "big", "comfortable", "perfect",
        "weak", "soft", "tight", "safe", "definite", "clean", "full"
    ]
}
