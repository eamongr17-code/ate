import Foundation

/// **A dietary tag on a dish** (`DietTagsB.dc.html`, 2026-09-26): a small linen chip after the dish's
/// name, in the words and on the card's dish row.
///
/// Five codes, lowercase on the wire (`entry_cards` items carry `tags: [String]`). The sorter reads
/// them out of the body exactly as it reads a score, so nothing about a tag is sent beside the words.
public enum DietTag: String, CaseIterable, Codable, Sendable, Hashable {
    // The wire's own codes, one letter included.
    // swiftlint:disable:next identifier_name
    case gf, df, v, vg, nf

    /// A code as the person typed it, in any case. `nil` for anything that is not one of the five.
    public init?(code: String) {
        self.init(rawValue: code.lowercased())
    }

    /// What the chip prints: the code in capitals.
    public var label: String { rawValue.uppercased() }

    /// What VoiceOver says — the chip's two letters are an abbreviation, not a word.
    public var spokenName: String {
        switch self {
        case .gf: "gluten free"
        case .df: "dairy free"
        case .v: "vegetarian"
        case .vg: "vegan"
        case .nf: "nut free"
        }
    }

    /// Codes off the wire, in order, unknown ones dropped and repeats folded. A tag the app does
    /// not know yet is not an error — it is simply not drawn.
    public static func decoding(_ codes: [String]) -> [DietTag] {
        var seen: Set<DietTag> = []
        return codes.compactMap(DietTag.init(code:)).filter { seen.insert($0).inserted }
    }
}

/// A tag as it sits in the words: which tag, and the characters the person typed for it. The
/// characters are kept verbatim — "GF" stays "GF" in the body (design rule 9) — and the chip prints
/// the tag's own label either way.
public struct DietTagMark: Hashable, Codable, Sendable {
    public var tag: DietTag
    public var text: String

    public init(tag: DietTag, text: String) {
        self.tag = tag
        self.text = text
    }

    public init(_ tag: DietTag) {
        self.init(tag: tag, text: tag.rawValue)
    }
}

/// **Where a tag chip sits in the body**, as the sort request carries it (`sort-entry`'s
/// `tag_tokens`, contract #61): a 0-based offset and a length in **Unicode scalars** — the unit the
/// server counts in, never UTF-16. The chip's letters stay in the body; the server attaches the tag
/// to the dish it follows.
public struct TagToken: Codable, Hashable, Sendable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }
}

/// `PATCH /rest/v1/reviews?id=eq.<review_id>` — a dish line's **whole** tag set, lowercase codes;
/// `[]` clears it. Owner-only; an unknown code is `23514`, which the enum makes unsendable.
public struct ReviewTagsPatch: Encodable, Hashable, Sendable {
    public let tags: [DietTag]

    public init(tags: [DietTag]) {
        var seen: Set<DietTag> = []
        self.tags = tags.filter { seen.insert($0).inserted }
    }
}

/// The body of `POST /functions/v1/sort-entry`. `tag_tokens` is sent only when there are chips, so
/// a sort without any is byte-for-byte the request it always was.
public struct SortEntryRequest: Encodable, Sendable {
    public let entryID: UUID
    public let force: Bool
    public let dryRun: Bool
    public let tagTokens: [TagToken]

    public init(entryID: UUID, force: Bool, dryRun: Bool = false, tagTokens: [TagToken] = []) {
        self.entryID = entryID
        self.force = force
        self.dryRun = dryRun
        self.tagTokens = tagTokens
    }

    enum CodingKeys: String, CodingKey {
        case force
        case entryID = "entry_id"
        case dryRun = "dry_run"
        case tagTokens = "tag_tokens"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryID, forKey: .entryID)
        try container.encode(force, forKey: .force)
        try container.encode(dryRun, forKey: .dryRun)
        if tagTokens.isEmpty == false {
            try container.encode(tagTokens, forKey: .tagTokens)
        }
    }
}

public extension EntryComposition {
    /// **The words a token is about** — up to three words before it, as the score slider's title.
    ///
    /// Read from the end of the last *score* before it, so an earlier pill's digits are never read
    /// as a name ("The ragù 0.5 0.5" once titled a panel "5 0 5"). Tag chips are skipped over, not
    /// stopped at: "Tiramisu v ★" is about the tiramisu, and a chip's letters are not part of its
    /// name. A stand-in for the sorter, which is what really names the dish, so it is never written
    /// anywhere; `nil` when there are no words to use.
    func dishWords(beforeTokenID tokenID: UUID) -> String? {
        guard let target = spans.first(where: { $0.token.id == tokenID }) else { return nil }
        let units = Array(plain.utf16)
        let start = spans
            .last { $0.span.endLocation <= target.span.location && $0.token.tag == nil }?
            .span.endLocation ?? 0
        let end = min(target.span.location, units.count)
        guard start < end else { return nil }
        // The window, with every tag chip inside it blanked out.
        var window = Array(units[start..<end])
        for tag in spans where tag.token.tag != nil && tag.span.location >= start && tag.span.endLocation <= end {
            for index in (tag.span.location - start)..<(tag.span.endLocation - start) { window[index] = 32 }
        }
        let words = String(decoding: window, as: UTF16.self)
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .suffix(3)
            .joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Every tag chip in these words, located in Unicode scalars for the sort request. The two units
    /// part company at anything outside the Basic Multilingual Plane — an emoji earlier in the words
    /// is two UTF-16 units and one scalar — so the conversion is done, never assumed.
    var tagTokens: [TagToken] {
        let tagSpans = spans.filter { $0.token.tag != nil }.map(\.span)
        guard tagSpans.isEmpty == false else { return [] }
        // UTF-16 offset → scalar offset, one walk over the words.
        var scalarAt: [Int: Int] = [:]
        var utf16 = 0
        var scalar = 0
        for unicodeScalar in plain.unicodeScalars {
            scalarAt[utf16] = scalar
            utf16 += unicodeScalar.utf16.count
            scalar += 1
        }
        scalarAt[utf16] = scalar
        return tagSpans.compactMap { span in
            guard let start = scalarAt[span.location], let end = scalarAt[span.endLocation] else { return nil }
            return TagToken(offset: start, length: end - start)
        }
    }
}

/// **"Typing gf, v or vg straight after a dish turns into the tag, as a number turns into a
/// score."** (`DietTagsB.dc.html`.)
///
/// The whole rule as one pure function, with the same bias ``ScoreLiteral`` has — hard toward NOT
/// converting. Two letters are far more ambiguous than a half-step number: "my gf", "a v good
/// night". So a code only becomes a tag when it follows a word that could end a dish's name, and
/// never after the handful of small words that make it mean something else.
public enum DietTagLiteral {
    /// The code the person just finished typing, ending at `caret`, if it can only be a tag.
    public static func candidate(in plain: String, caretUTF16 caret: Int) -> (span: TextSpan, mark: DietTagMark)? {
        let units = Array(plain.utf16)
        guard caret > 0, caret <= units.count else { return nil }

        var start = caret
        while start > 0, isASCIILetter(units[start - 1]) { start -= 1 }
        guard start < caret, caret - start <= 2 else { return nil }
        let literal = String(decoding: units[start..<caret], as: UTF16.self)
        guard let tag = DietTag(code: literal) else { return nil }

        // Nothing but a boundary after it: "gfx" is not a tag.
        if caret < units.count, let scalar = Unicode.Scalar(units[caret]),
           CharacterSet.alphanumerics.contains(scalar) {
            return nil
        }
        // Exactly one space in front, then a word — the end of a dish's name.
        guard start >= 2, units[start - 1] == space else { return nil }
        var wordEnd = start - 1
        while wordEnd > 0, units[wordEnd - 1] == space { wordEnd -= 1 }
        guard wordEnd > 0, let last = Unicode.Scalar(units[wordEnd - 1]),
              CharacterSet.letters.contains(last) else { return nil }
        var wordStart = wordEnd
        while wordStart > 0, let scalar = Unicode.Scalar(units[wordStart - 1]),
              CharacterSet.letters.contains(scalar) || units[wordStart - 1] == apostrophe {
            wordStart -= 1
        }
        let word = String(decoding: units[wordStart..<wordEnd], as: UTF16.self).lowercased()
        guard disqualifying.contains(word) == false else { return nil }

        return (TextSpan(location: start, length: caret - start), DietTagMark(tag: tag, text: literal))
    }

    // MARK: - Pieces

    private static let space = UInt16(32)
    private static let apostrophe = UInt16(39)

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    /// Words after which two letters are not a dish's tag: pronouns ("my gf"), articles, the
    /// small verbs and adverbs "v" is shorthand for "very" after, and the connectives.
    static let disqualifying: Set<String> = [
        "a", "an", "the", "my", "his", "her", "your", "our", "their", "its", "me", "i", "we", "you",
        "he", "she", "they", "it", "with", "and", "or", "but", "to", "for", "of", "at", "in", "on",
        "is", "was", "were", "are", "be", "been", "so", "not", "too", "also", "just", "really",
        "very", "quite", "pretty", "got", "had", "have", "felt", "looked", "tasted", "went"
    ]
}
