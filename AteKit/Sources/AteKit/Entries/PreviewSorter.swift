#if DEBUG
import Foundation

/// **A dumb local stand-in for the server's sorter — previews and tests only.**
///
/// The server is the single source of structure (`supabase/functions/sort-entry`), and this must
/// never pretend otherwise: it is compiled only into Debug, so a Beta or Release binary does not
/// contain it at all, and nothing outside the in-memory service can reach it.
///
/// What it does is the smallest rule from `parse.ts` that produces a believable receipt: a decimal
/// number sitting right after some words is that dish's score, the words before it name the dish,
/// and the rest of the sentence is the note. It shares the real parser's *bias* — it would rather
/// find no dish than a wrong one, and it never invents a score from sentiment — but it is not the
/// same parser and is not expected to agree with it.
public enum PreviewSorter {
    public struct Line: Sendable, Hashable {
        public var dishName: String
        public var score: Rating?
        public var note: String?
    }

    public static func sort(body: String) -> [Line] {
        var lines: [Line] = []
        for sentence in sentences(in: body) {
            guard let line = line(from: sentence) else { continue }
            lines.append(line)
        }
        return lines
    }

    /// Split on `.`, `!`, `?` and newlines — but never on the dot inside a decimal, which is the
    /// first bug the real corpus caught.
    private static func sentences(in body: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(body)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                sentences.append(current)
                current = ""
                continue
            }
            let isDecimalPoint = character == "."
                && index > 0 && characters[index - 1].isNumber
                && index + 1 < characters.count && characters[index + 1].isNumber
            if ".!?".contains(character), isDecimalPoint == false {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        sentences.append(current)
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
    }

    private static func line(from sentence: String) -> Line? {
        let words = sentence.split(separator: " ").map(String.init)
        guard let scoreIndex = words.firstIndex(where: { rating(for: $0) != nil }) else { return nil }
        let name = dishName(from: words[..<scoreIndex])
        guard name.isEmpty == false else { return nil }
        let rest = words[(scoreIndex + 1)...].joined(separator: " ")
        let terminated = rest.last.map { ",.;:!?".contains($0) } ?? true
        return Line(
            dishName: name,
            score: rating(for: words[scoreIndex]),
            // A note is only ever a literal slice of what they wrote — never a paraphrase.
            note: rest.isEmpty ? nil : (terminated ? rest : rest + ".")
        )
    }

    /// The two or three words before the number, minus the noise ones. The real sorter matches
    /// against the menu too; this cannot, so it stays short rather than guessing long.
    private static func dishName(from words: ArraySlice<String>) -> String {
        let stop: Set<String> = [
            "the", "a", "an", "and", "with", "for", "at", "in", "on", "of", "to", "my", "her", "his",
            "their", "our", "was", "were", "is", "are", "had", "got", "we", "i", "they", "it", "then",
            "after", "that", "this", "very", "really", "just", "but", "so"
        ]
        let candidate = words
            .suffix(4)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) }
            .filter { stop.contains($0.lowercased()) == false && $0.isEmpty == false }
            .suffix(3)
        return candidate.joined(separator: " ")
    }

    private static func rating(for word: String) -> Rating? {
        let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        guard cleaned.contains("."), let value = Double(cleaned) else { return nil }
        return Rating(exactly: value)
    }
}
#endif
