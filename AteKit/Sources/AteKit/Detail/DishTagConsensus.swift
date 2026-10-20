import Foundation

/// **A dish's diet labels, as everybody marked it** — the server's rule (`dish_summary.tags` and
/// `diet_counts`), written down once for the in-memory stand-ins that have to agree with it. The
/// live pages never compute this: they draw the server's `tags` and `diet_counts` as they come.
///
/// A code is a **label** once at least ``labelPeople`` different people have marked it on the dish;
/// below that it is a **count** (1–2) the dish page prints as "Ordered by N … eaters". The marks are
/// the users' own (typed chips, or stamped from their diet); this only counts them, and never adds a
/// code nobody marked (design rule 7's spirit). Canonical order — gf, df, v, vg, nf.
///
/// (The server also drops a label a person of that diet turned off, over the last 12 months; the
/// stand-ins hold neither, so that half is the server's alone.)
public enum DishTagConsensus {
    /// The server's threshold.
    public static let labelPeople = 3

    /// `marks`: each line's author and the codes on it.
    public static func labels(marks: [(person: UUID, tags: [DietTag])]) -> (tags: [DietTag], counts: DietCounts) {
        var people: [DietTag: Set<UUID>] = [:]
        for mark in marks {
            for tag in Set(mark.tags) { people[tag, default: []].insert(mark.person) }
        }
        let tags = DietTag.allCases.filter { (people[$0]?.count ?? 0) >= labelPeople }
        var counts: [DietTag: Int] = [:]
        for tag in DietTag.allCases where tags.contains(tag) == false {
            let count = people[tag]?.count ?? 0
            if count > 0 { counts[tag] = count }
        }
        return (tags, DietCounts(counts))
    }
}
