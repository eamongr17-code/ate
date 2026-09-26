import Foundation

/// **A dish's dietary tags, as everybody tagged it** — `dish_summary.tags`' rule (0036), written
/// down once so the in-memory pages, and any client that ever has to agree with the server, use it.
///
/// A code is the dish's when **at least half** of its lines carry it, and at least one does. The
/// tags are the users' own chips; this only counts them, and never adds a code nobody typed
/// (design rule 7's spirit: nothing about a dish is inferred). Canonical order — gf, df, v, vg, nf.
public enum DishTagConsensus {
    public static func tags(lines: [[DietTag]]) -> [DietTag] {
        guard lines.isEmpty == false else { return [] }
        return DietTag.allCases.filter { tag in
            let carrying = lines.filter { $0.contains(tag) }.count
            return carrying > 0 && carrying * 2 >= lines.count
        }
    }
}
