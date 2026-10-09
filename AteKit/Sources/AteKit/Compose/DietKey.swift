import Foundation

public extension EntryComposition {
    /// What the Diet key did: put a chip in, or took the dish's own back out.
    enum DietKeyEdit: Equatable, Sendable {
        case added(DietTag)
        case removed(DietTag)
    }

    /// A Diet key press, done: the words after it, where the caret goes, and which way it went.
    struct DietKeyResult: Equatable, Sendable {
        public let composition: EntryComposition
        public let caret: Int
        public let edit: DietKeyEdit
    }

    /// **The Diet key, pressed** (Eamon, 7 Oct): a dish wears each code once. A code the dish's
    /// chips already carry comes back off; anything else goes in as ``insertingTag(_:atDisplayOffset:)``
    /// puts it. `nil` when there is nothing to do (no dish to wear it).
    func togglingTag(_ tag: DietTag, atDisplayOffset caret: Int) -> DietKeyResult? {
        if let worn = dishTagSpans(atDisplayOffset: caret).first(where: { $0.token.tag == tag }) {
            let (next, newCaret) = removingTag(worn, caret: caret)
            return DietKeyResult(composition: next, caret: newCaret, edit: .removed(tag))
        }
        guard let (next, newCaret) = insertingTag(tag, atDisplayOffset: caret) else { return nil }
        return DietKeyResult(composition: next, caret: newCaret, edit: .added(tag))
    }

    /// The codes already on the dish a chip at `caret` would belong to.
    func dishTags(atDisplayOffset caret: Int) -> [DietTag] {
        dishTagSpans(atDisplayOffset: caret).compactMap(\.token.tag)
    }

    /// **The dish's chips** — the run of tag chips, only spaces between them, at the place the key
    /// would put a new one: the caret, or in front of the score that ends just before it.
    private func dishTagSpans(atDisplayOffset caret: Int) -> [EntryTokenSpan] {
        let anchor = scoreEnding(beforeDisplayOffset: caret)?.span.location
            ?? plainOffset(forDisplayOffset: caret)
        return tagCluster(around: anchor)
    }

    /// Every tag chip touching `plainOffset` through spaces alone, either side, in order.
    func tagCluster(around plainOffset: Int) -> [EntryTokenSpan] {
        let units = Array(plain.utf16)
        let tags = spans.filter { $0.token.tag != nil }
        var before: [EntryTokenSpan] = []
        var cursor = plainOffset
        while true {
            while cursor > 0, units[cursor - 1] == 32 { cursor -= 1 }
            guard let chip = tags.first(where: { $0.span.endLocation == cursor }) else { break }
            before.insert(chip, at: 0)
            cursor = chip.span.location
        }
        var after: [EntryTokenSpan] = []
        cursor = plainOffset
        while true {
            while cursor < units.count, units[cursor] == 32 { cursor += 1 }
            guard let chip = tags.first(where: { $0.span.location == cursor }) else { break }
            after.append(chip)
            cursor = chip.span.endLocation
        }
        return before + after
    }

    /// A chip out, with one of the spaces it brought in, so "tiramisu GF 3.0" becomes "tiramisu
    /// 3.0" and not "tiramisu  3.0". The caret keeps its place in the words around it.
    private func removingTag(_ chip: EntryTokenSpan, caret: Int) -> (EntryComposition, caret: Int) {
        let units = Array(plain.utf16)
        var range = chip.span
        if range.endLocation < units.count, units[range.endLocation] == 32 {
            range = TextSpan(location: range.location, length: range.length + 1)
        } else if range.location > 0, units[range.location - 1] == 32 {
            range = TextSpan(location: range.location - 1, length: range.length + 1)
        }
        let start = displayOffset(forPlainOffset: range.location)
        let removed = displayOffset(forPlainOffset: range.endLocation) - start
        let next = applyingPlainEdit(replacing: range, with: "")
        let newCaret = caret > start ? max(start, caret - removed) : caret
        return (next, min(newCaret, next.displayString.utf16.count))
    }

    /// **The Diet key** (prototype, round 3): puts a tag chip after the current dish.
    ///
    /// A chip belongs to **the nearest dish to its left** — the sorter's own rule (it attaches a
    /// `tag_token` to the dish named nearest before it), so the chip the person sees is the tag that
    /// is saved. Where it goes:
    ///
    /// - just after a score pill (only whitespace between): in front of that pill, between the dish
    ///   and its score — "tiramisu v 3.0", the order the sorter and ``EntryBodyTokens`` read;
    /// - anywhere else: at the caret, which is where the dish being written ends — or, several words
    ///   on, where the person wants it; it still belongs to the dish before it.
    ///
    /// **`nil` when nothing to the left could be a dish** (``hasDishCandidate(beforeDisplayOffset:)``):
    /// a chip with no dish before it would be dropped by the sorter and print as two loose letters,
    /// so the key inserts nothing at all. The caret stays after everything it was after.
    func insertingTag(_ tag: DietTag, atDisplayOffset caret: Int) -> (EntryComposition, caret: Int)? {
        let token = EntryToken(kind: .tag(DietTagMark(tag: tag, text: tag.label)))
        guard let score = scoreEnding(beforeDisplayOffset: caret) else {
            guard hasDishCandidate(beforeDisplayOffset: caret) else { return nil }
            return inserting(token, atDisplayOffset: caret)
        }
        let (next, _) = inserting(token, atDisplayOffset: displayOffset(forPlainOffset: score.span.location))
        let added = next.displayString.utf16.count - displayString.utf16.count
        return (next, caret: caret + added)
    }

    /// Whether anything before `offset` could be a dish for a chip to belong to.
    ///
    /// The composer cannot know dishes — the sorter names them — so this errs the sorter's way:
    /// a score or tag pill (each only ever follows a dish) counts, and so does any word that is not
    /// one of the small words a dish's name never is ("with my", "and the", ``DietTagLiteral``'s
    /// list) nor itself a diet code. An empty draft, or one that is only such words, has none.
    func hasDishCandidate(beforeDisplayOffset offset: Int) -> Bool {
        let plainOffset = self.plainOffset(forDisplayOffset: offset)
        if spans.contains(where: { $0.span.endLocation <= plainOffset && $0.token.place == nil }) {
            return true
        }
        let covered = spans.map(\.span)
        let units = Array(plain.utf16.prefix(plainOffset))
        var index = 0
        while index < units.count {
            guard isWordUnit(units[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < units.count, isWordUnit(units[end]) { end += 1 }
            let span = TextSpan(location: index, length: end - index)
            let word = String(decoding: units[index..<end], as: UTF16.self).lowercased()
            if covered.contains(where: { $0.intersects(span) }) == false,
               DietTagLiteral.disqualifying.contains(word) == false,
               DietTag(code: word) == nil {
                return true
            }
            index = end
        }
        return false
    }

    private func isWordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar) || unit == 39
    }

    /// The score pill that ends just before `offset`, with nothing but spaces between.
    private func scoreEnding(beforeDisplayOffset offset: Int) -> EntryTokenSpan? {
        var plainOffset = self.plainOffset(forDisplayOffset: offset)
        let units = Array(plain.utf16)
        while plainOffset > 0, units[plainOffset - 1] == 32 { plainOffset -= 1 }
        return spans.first { $0.token.score != nil && $0.span.endLocation == plainOffset }
    }
}
