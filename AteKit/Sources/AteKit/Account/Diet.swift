import Foundation

// MARK: - A diet, as a person picks it

public extension DietTag {
    /// **What a person who eats this way picks** (`design/rebuild/diet.html`): the onboarding chip,
    /// the Settings → Diet row, and the place page's chip.
    var dietName: String {
        switch self {
        case .gf: "Gluten free"
        case .df: "Dairy free"
        case .v: "Vegetarian"
        case .vg: "Vegan"
        case .nf: "Nut free"
        }
    }

    /// The eater the dish page counts: "Ordered by 2 **vegan** eaters".
    var eaterWord: String {
        switch self {
        case .gf: "gluten-free"
        case .df: "dairy-free"
        case .v: "vegetarian"
        case .vg: "vegan"
        case .nf: "nut-free"
        }
    }

    /// What this code covers beyond itself: vegan is vegetarian and dairy free.
    var covers: Set<DietTag> {
        self == .vg ? [.v, .df] : []
    }
}

/// **The codes a person always eats by** — `profiles.diet`, as the onboarding chips and the
/// Settings tick list hold it.
///
/// Stored is only what was picked (`["vg"]`); what a pick covers (Vegan → Vegetarian, Dairy free)
/// is drawn lit, faded and locked, and never stored. Picking Vegan takes Vegetarian and Dairy free
/// out of the picks, so they read as covered rather than as two more choices that can't be undone.
public struct DietChoice: Hashable, Sendable {
    public private(set) var picked: Set<DietTag>

    public init(_ codes: [DietTag] = []) {
        let picked = Set(codes)
        let covered = picked.reduce(into: Set<DietTag>()) { $0.formUnion($1.covers) }
        self.picked = picked.subtracting(covered)
    }

    /// What is stored, in the canonical order (gf, df, v, vg, nf).
    public var codes: [DietTag] { DietTag.allCases.filter(picked.contains) }

    public var isEmpty: Bool { picked.isEmpty }

    /// Covered by another pick: lit, faded, and not a button.
    public func isCovered(_ tag: DietTag) -> Bool {
        picked.contains(tag) == false && picked.contains { $0.covers.contains(tag) }
    }

    public func isPicked(_ tag: DietTag) -> Bool { picked.contains(tag) }

    /// A tap. `nil` for a code another pick covers — it does nothing.
    public func toggling(_ tag: DietTag) -> DietChoice? {
        guard isCovered(tag) == false else { return nil }
        var next = self
        if next.picked.contains(tag) {
            next.picked.remove(tag)
        } else {
            next.picked.insert(tag)
            next.picked.subtract(tag.covers)
        }
        return next
    }

    /// The Settings row's value: "Vegan", "Gluten free, Nut free", "None".
    public var summary: String {
        codes.isEmpty ? "None" : codes.map(\.dietName).joined(separator: ", ")
    }
}

// MARK: - What everybody else marked a dish

/// **A dish's diet codes below the label** — `diet_counts` on `dish_summary` and on the place page's
/// dish rows: `{code: n}`, n of 1–2, for a code not yet labelled (the server labels at 3 people).
/// Decoded leniently: an unknown code, a zero, or an older server with no object at all is simply
/// nothing.
public struct DietCounts: Hashable, Sendable, Codable {
    private var counts: [DietTag: Int]

    public init(_ counts: [DietTag: Int] = [:]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: Int].self)) ?? [:]
        var counts: [DietTag: Int] = [:]
        for (code, count) in raw {
            guard let tag = DietTag(code: code), count > 0 else { continue }
            counts[tag] = count
        }
        self.counts = counts
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }))
    }

    public subscript(tag: DietTag) -> Int { counts[tag] ?? 0 }

    /// The codes counted, canonical order.
    public var codes: [DietTag] { DietTag.allCases.filter { self[$0] > 0 } }

    public var isEmpty: Bool { counts.isEmpty }
}

/// One line about a dish and one diet: labelled (the code's chip), or the literal count below it.
public enum DietSignal: Hashable, Sendable, Identifiable {
    case labelled(DietTag)
    case orderedBy(DietTag, count: Int)

    public var id: String {
        switch self {
        case .labelled(let tag): "labelled:\(tag.rawValue)"
        case .orderedBy(let tag, _): "ordered:\(tag.rawValue)"
        }
    }

    public var tag: DietTag {
        switch self {
        case .labelled(let tag), .orderedBy(let tag, _): tag
        }
    }

    /// "Ordered by 2 vegan eaters", "Ordered by 1 gluten-free eater". `nil` for a label: it is the
    /// chip alone.
    public var line: String? {
        guard case .orderedBy(let tag, let count) = self else { return nil }
        return "Ordered by \(count) \(tag.eaterWord) \(count == 1 ? "eater" : "eaters")"
    }

    /// **The dish page, under the aggregate**: one line per counted code that is not labelled. The
    /// labelled ones are already the chips beside the people count.
    public static func belowLabel(tags: [DietTag], counts: DietCounts) -> [DietSignal] {
        counts.codes
            .filter { tags.contains($0) == false }
            .map { .orderedBy($0, count: counts[$0]) }
    }

    /// **A place's dish row while the viewer's diet chips are on**: per code that is on, its chip if
    /// the dish is labelled with it, otherwise the count, otherwise nothing.
    public static func forFilter(_ on: [DietTag], tags: [DietTag], counts: DietCounts) -> [DietSignal] {
        on.compactMap { code in
            if tags.contains(code) { return .labelled(code) }
            let count = counts[code]
            return count > 0 ? .orderedBy(code, count: count) : nil
        }
    }

    /// Whether a dish stays in The Top Ate with these codes on: labelled with every one of them, or
    /// counted for it. Nothing on keeps every dish.
    public static func passes(_ on: [DietTag], tags: [DietTag], counts: DietCounts) -> Bool {
        on.allSatisfy { tags.contains($0) || counts[$0] > 0 }
    }
}
