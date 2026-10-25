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
        case .pe: "Pescatarian"
        case .ha: "Halal"
        case .ef: "Egg free"
        case .pf: "Peanut free"
        case .sf: "Shellfish free"
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
        case .pe: "pescatarian"
        case .ha: "halal"
        case .ef: "egg-free"
        case .pf: "peanut-free"
        case .sf: "shellfish-free"
        }
    }

    /// What this code covers beyond itself (0084): vegan is vegetarian, pescatarian, dairy free and
    /// egg free; vegetarian is pescatarian; nut free is peanut free. The whole reach, not one step.
    var covers: Set<DietTag> {
        switch self {
        case .vg: [.v, .pe, .df, .ef]
        case .v: [.pe]
        case .nf: [.pf]
        default: []
        }
    }

    /// An allergy rather than a way of eating (`diet-more.html`): Settings lists these under
    /// "Allergies", and their counts end with the reminder to check with staff.
    var isAllergy: Bool {
        switch self {
        case .gf, .ef, .nf, .pf, .sf: true
        default: false
        }
    }

    /// **The order a person picks in** (`diet-more.html`): the ways of eating, then the allergies.
    static let pickingOrder: [DietTag] = diets + allergies
    /// Settings' "Diets" group.
    static let diets: [DietTag] = [.v, .vg, .pe, .ha, .df]
    /// Settings' "Allergies" group.
    static let allergies: [DietTag] = [.gf, .ef, .nf, .pf, .sf]
}

/// **The codes a person always eats by** — `profiles.diet`, as the onboarding chips and the
/// Settings tick list hold it.
///
/// Stored is only what was picked (`["vg"]`); what a pick covers (Vegan → Vegetarian, Pescatarian,
/// Dairy free, Egg free; Vegetarian → Pescatarian; Nut free → Peanut free) is drawn lit, faded and
/// locked, and never stored. Picking Vegan takes what it covers out of the picks, so they read as
/// covered rather than as more choices that can't be undone.
public struct DietChoice: Hashable, Sendable {
    public private(set) var picked: Set<DietTag>

    public init(_ codes: [DietTag] = []) {
        let picked = Set(codes)
        let covered = picked.reduce(into: Set<DietTag>()) { $0.formUnion($1.covers) }
        self.picked = picked.subtracting(covered)
    }

    /// What is stored, in the canonical order (gf, df, v, vg, nf, pe, ha, ef, pf, sf).
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

    /// The Settings row's value, in picking order: "Vegan", "Halal, Nut free", "None".
    public var summary: String {
        let picks = DietTag.pickingOrder.filter(picked.contains)
        return picks.isEmpty ? "None" : picks.map(\.dietName).joined(separator: ", ")
    }
}

// MARK: - What everybody else marked a dish

/// **How many people of each diet logged a dish** — `diet_counts` on `dish_summary` and on the place
/// page's dish rows: `{code: n}` for every code somebody counted and nobody turned off (0084; an
/// older server sent only the codes below the label, n of 1–2).
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

// MARK: - The "?" popover

/// **One line of a dish's "?" popover** (`diet-more.html`): the code's pill, its name, and how many
/// people of that diet logged the dish. The pills alone say nothing about numbers; this is where
/// they are.
public struct DietCountLine: Hashable, Sendable, Identifiable {
    public let tag: DietTag
    /// `nil` for a label an older server sent no count for (it counted only below the label).
    public let people: Int?

    public init(tag: DietTag, people: Int?) {
        self.tag = tag
        self.people = people
    }

    public var id: String { tag.rawValue }

    /// What the line prints after the person glyph: the count, or "3+" for a label with none.
    public var peopleText: String {
        people.map(String.init) ?? "\(DishTagConsensus.labelPeople)+"
    }

    /// The dish page's lines: the labels in the order the pills print them, then every other code
    /// somebody counted (no pill yet), canonical order.
    public static func dish(tags: [DietTag], counts: DietCounts) -> [DietCountLine] {
        let labelled = tags.map { DietCountLine(tag: $0, people: counts[$0] > 0 ? counts[$0] : nil) }
        let counted = counts.codes
            .filter { tags.contains($0) == false }
            .map { DietCountLine(tag: $0, people: counts[$0]) }
        return labelled + counted
    }
}
