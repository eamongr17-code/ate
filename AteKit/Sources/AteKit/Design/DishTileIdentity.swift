import Foundation

/// **A dish is never a blank** (design-language §3). Where a dish needs a visual anchor and has no
/// photo, it gets a tile generated from its own identity — so an imageless menu reads as a menu
/// rather than as fifteen failed loads.
///
/// The *rules* for what a tile says and which tone it takes live here, UI-free and tested, because
/// they are the part that can be quietly wrong: a monogram that picks the stop-word ("Of"), a
/// palette that reshuffles between launches, a name that doesn't degrade in a 44pt square.
public enum DishTileIdentity {

    // MARK: - Monogram (variant B)

    /// Two letters that stand for the dish: the initials of its first two *significant* words, or
    /// the first two letters when there is only one.
    ///
    /// "Prawn betel leaf" → `PB`. "Cacio e Pepe" → `CP` (the conjunction is skipped, which is the
    /// whole reason this isn't `String.prefix(2)`). "Tonkotsu" → `TO`. A name with nothing
    /// alphanumeric in it falls back to the placeholder rather than rendering an empty square.
    public static func monogram(for name: String) -> String {
        let words = significantWords(in: name)
        guard let first = words.first else { return monogramPlaceholder }
        if words.count >= 2, let second = words[1].first, let lead = first.first {
            return String([lead, second]).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    /// What a nameless dish shows. Never an empty tile.
    public static let monogramPlaceholder = "??"

    // MARK: - Typographic (variant A)

    /// How much of the name a typographic tile can carry before it stops being legible and starts
    /// being texture.
    public enum TypographicDetail: Sendable, Hashable {
        /// The whole name, over-scaled and clipped by the well.
        case fullName
        /// The first significant word only.
        case firstWord
        /// Down to the monogram — below this size a word is a smear.
        case twoLetters
    }

    /// §3: full name in a large well, first word at 44pt, two letters below 32pt.
    public static func typographicDetail(forWell size: Double) -> TypographicDetail {
        if size < twoLetterCeiling { return .twoLetters }
        if size < fullNameFloor { return .firstWord }
        return .fullName
    }

    /// The string a typographic tile renders for a name in a well of the given size.
    public static func typographicText(for name: String, well size: Double) -> String {
        switch typographicDetail(forWell: size) {
        case .fullName:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? monogram(for: name) : trimmed
        case .firstWord:
            return significantWords(in: name).first.map(String.init) ?? monogram(for: name)
        case .twoLetters:
            return monogram(for: name)
        }
    }

    /// Below 32pt a word can't survive. Matches `Theme.Size.tileSmall`'s neighbourhood on purpose:
    /// the diary's 44pt tile is the first size that still reads as a word.
    private static let twoLetterCeiling: Double = 32
    /// At and above this the well is big enough for a whole dish name to run out of it.
    private static let fullNameFloor: Double = 56

    // MARK: - Palette

    /// Which step of the (brand-owned) tile palette this dish takes.
    ///
    /// **Deliberately not `hashValue`.** Swift's `Hashable` is seeded per process, so a
    /// `hashValue`-indexed palette would repaint every dish on every launch — the tile is supposed
    /// to be part of a dish's identity, not a mood ring. This is a plain FNV-1a over the UUID's 16
    /// bytes: stable across launches, devices and OS versions, and cheap enough to call per row.
    public static func paletteIndex(for id: UUID, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(stableHash(of: id) % UInt64(count))
    }

    static func stableHash(of id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    // MARK: - Words

    /// Words that carry no identity. Kept short and lowercase-compared: this is a display heuristic,
    /// not a linguistics project, and over-filtering ("Eggs Benedict" → "BE") is the worse failure.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "and", "with", "in", "on", "e", "de", "la", "le", "el", "y", "et", "au", "aux"
    ]

    /// The name's words, minus stop words and minus anything with no letter or digit in it. Falls
    /// back to the unfiltered words when filtering would leave nothing ("A La Carte" is all stops).
    static func significantWords(in name: String) -> [Substring] {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .map { $0.drop(while: { !$0.isLetter && !$0.isNumber }) }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        let significant = words.filter { !stopWords.contains($0.lowercased()) }
        return significant.isEmpty ? words : significant
    }
}
