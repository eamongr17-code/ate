import Foundation

/// **A diet code NOT to stamp on one dish** — `sort-entry`'s `diet_off_tokens`. The same shape and
/// attachment rule as a ``TagToken`` (a 0-based offset and a length in **Unicode scalars**, attached
/// by the server to the dish named nearest at or before it), plus the code it turns off.
///
/// The span is the last word of the dish as the composer saw it — words the person wrote, never
/// added to: nothing about turning a code off goes into the body (design rule 9).
public struct DietOffToken: Codable, Hashable, Sendable {
    public let offset: Int
    public let length: Int
    public let code: DietTag

    public init(offset: Int, length: Int, code: DietTag) {
        self.offset = offset
        self.length = length
        self.code = code
    }
}

/// **The author's diet in the composer** (`design/rebuild/diet.html`, "Turning it off for one
/// dish"): the Diet key's codes for the dish at the caret show the diet's codes already lit; a tap
/// turns one off for that dish only, another turns it back on. Nothing is written into the words.
///
/// Two modes, one rule — a code belongs to **the dish on its left** (the Diet key's and the sorter's):
///
/// - **a new entry**: the lit codes are the author's diet; a code turned off is remembered against
///   the dish's last word and sent as a ``DietOffToken``;
/// - **an edit**: the lit codes are the line's own ``EntryCard/Item/dietTags`` (the ones the author
///   never sees on their own screens); a code turned off is that line's tag set PATCHed without it
///   (``EditTagDiff``, `setTags`), which the server records as the dish's diet-off.
///
/// The words move under it as the person types; ``follow(from:to:)`` keeps every remembered span on
/// the characters it was on, and forgets one whose characters were edited away.
public struct ComposerDiet: Hashable, Sendable {
    /// A code turned off on a new entry: which, and the dish's last word.
    public struct Off: Hashable, Sendable {
        public var word: TextSpan
        public let tag: DietTag
    }

    /// A saved line, on an edit: where its dish is named in the words, and its diet's codes.
    public struct Line: Hashable, Sendable {
        public let reviewID: UUID
        public var mention: TextSpan?
        public let dietTags: [DietTag]
    }

    /// Which way a tap went.
    public enum Toggle: Equatable, Sendable {
        case off(DietTag)
        case on(DietTag)
    }

    /// The author's diet, as stored — what a new entry's dishes are stamped with.
    public let diet: [DietTag]
    public let isEditing: Bool
    public private(set) var offs: [Off] = []
    public private(set) var lines: [Line] = []
    /// On an edit: each line's codes turned off, by review id.
    public private(set) var removals: [UUID: Set<DietTag>] = [:]

    /// A new entry, for an author with this diet (`[]`: nothing is ever lit).
    public init(diet: [DietTag] = []) {
        self.diet = DietTag.allCases.filter { diet.contains($0) }
        self.isEditing = false
    }

    /// An edit of a saved entry whose words are `body`.
    public init(editing items: [EntryCard.Item], body: String) {
        self.diet = []
        self.isEditing = true
        let offsets = BodyOffsets(body)
        self.lines = items.map { item in
            Line(
                reviewID: item.reviewID,
                mention: offsets.span(scalarOffset: item.mentionOffset, scalarLength: item.mentionLength)
                    ?? offsets.occurrences(of: item.dishName).first,
                dietTags: item.dietTags
            )
        }
    }

    /// Anything turned off on an edit — the composer asks before throwing it away.
    public var hasRemovals: Bool { removals.isEmpty == false }

    // MARK: - The keys

    /// The codes the dish at the caret wears from the diet: lit in the Diet key's unfold.
    public func lit(in composition: EntryComposition, atDisplayOffset caret: Int) -> [DietTag] {
        if isEditing {
            guard let line = line(in: composition, atDisplayOffset: caret) else { return [] }
            let gone = removals[line.reviewID] ?? []
            return line.dietTags.filter { gone.contains($0) == false }
        }
        guard diet.isEmpty == false, let word = Self.dishWord(in: composition, atDisplayOffset: caret) else {
            return []
        }
        return diet.filter { offs.contains(Off(word: word, tag: $0)) == false }
    }

    /// A Diet key press for a code the diet manages on the dish at the caret: off, or back on.
    /// `nil` when the code is not the diet's for this dish (or there is no dish) — the key then does
    /// what it always did, a chip in the words.
    public mutating func toggle(
        _ tag: DietTag, in composition: EntryComposition, atDisplayOffset caret: Int
    ) -> Toggle? {
        if isEditing {
            guard let line = line(in: composition, atDisplayOffset: caret), line.dietTags.contains(tag) else {
                return nil
            }
            var gone = removals[line.reviewID] ?? []
            defer { removals[line.reviewID] = gone.isEmpty ? nil : gone }
            if gone.remove(tag) != nil { return .on(tag) }
            gone.insert(tag)
            return .off(tag)
        }
        guard diet.contains(tag), let word = Self.dishWord(in: composition, atDisplayOffset: caret) else {
            return nil
        }
        let off = Off(word: word, tag: tag)
        if let index = offs.firstIndex(of: off) {
            offs.remove(at: index)
            return .on(tag)
        }
        offs.append(off)
        return .off(tag)
    }

    // MARK: - The request

    /// `diet_off_tokens` for the words as they are now, in body order.
    public func offTokens(in plain: String) -> [DietOffToken] {
        let body = BodyOffsets(plain)
        return offs
            .compactMap { off in
                body.scalarSpan(of: off.word).map { DietOffToken(offset: $0.offset, length: $0.length, code: off.tag) }
            }
            .sorted { ($0.offset, $0.code.rawValue) < ($1.offset, $1.code.rawValue) }
    }

    // MARK: - The words moving

    /// The words changed from `old` to `new`: every remembered span moves with its characters. The
    /// change is read as one replaced run between the longest common prefix and suffix; a span that
    /// run touched is gone (its dish was rewritten), anything either side keeps its place.
    public mutating func follow(from old: String, to new: String) {
        guard old != new else { return }
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        let limit = min(before.count, after.count)
        var prefix = 0
        while prefix < limit, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        let changedEnd = before.count - suffix
        let delta = after.count - before.count
        func moved(_ span: TextSpan) -> TextSpan? {
            if span.endLocation <= prefix { return span }
            if span.location >= changedEnd { return TextSpan(location: span.location + delta, length: span.length) }
            return nil
        }
        offs = offs.compactMap { off in moved(off.word).map { Off(word: $0, tag: off.tag) } }
        lines = lines.map { line in
            var line = line
            line.mention = line.mention.flatMap(moved)
            return line
        }
    }

    // MARK: - Which dish

    /// The saved line the caret's dish is: the one whose mention holds the dish word on the left.
    /// `nil` for a dish typed during the edit — it has no line yet, and must never borrow the one before.
    func line(in composition: EntryComposition, atDisplayOffset caret: Int) -> Line? {
        guard let word = Self.dishWord(in: composition, atDisplayOffset: caret) else { return nil }
        return lines.first { line in
            guard let mention = line.mention else { return false }
            return word.location >= mention.location && word.endLocation <= mention.endLocation
        }
    }

    /// **The dish on the left, as a word**: the last word of the person's own before the place a
    /// chip would go (the caret, or in front of the score that ends just before it), stepping back
    /// over spaces, punctuation and pills. `nil` when nothing to the left could be a dish
    /// (``EntryComposition/hasDishCandidate(beforeDisplayOffset:)``).
    static func dishWord(in composition: EntryComposition, atDisplayOffset caret: Int) -> TextSpan? {
        guard composition.hasDishCandidate(beforeDisplayOffset: caret) else { return nil }
        let units = Array(composition.plain.utf16)
        let pills = composition.spans.map(\.span)
        var index = min(anchor(in: composition, atDisplayOffset: caret), units.count)
        func pill(endingAfter unit: Int) -> TextSpan? {
            pills.first { $0.location <= unit && unit < $0.endLocation }
        }
        while index > 0 {
            if let pill = pill(endingAfter: index - 1) {
                index = pill.location
            } else if isWordUnit(units[index - 1]) {
                break
            } else {
                index -= 1
            }
        }
        let end = index
        while index > 0, isWordUnit(units[index - 1]), pill(endingAfter: index - 1) == nil { index -= 1 }
        guard index < end else { return nil }
        return TextSpan(location: index, length: end - index)
    }

    private static func anchor(in composition: EntryComposition, atDisplayOffset caret: Int) -> Int {
        composition.scoreEnding(beforeDisplayOffset: caret)?.span.location
            ?? composition.plainOffset(forDisplayOffset: caret)
    }

    /// A letter, a digit or an apostrophe — what a dish's word is made of.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit == 39 || unit == 8217 { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
