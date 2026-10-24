import Foundation

/// **A dish's diet labels, as everybody marked it** — the server's rule (`dish_summary.tags` and
/// `diet_counts`), written down once for the in-memory stand-ins that have to agree with it. The
/// live pages never compute this: they draw the server's `tags` and `diet_counts` as they come.
///
/// A code is a **label** once at least ``labelPeople`` different people have marked it on the dish;
/// every counted code also carries its count, for the dish page's "?" popover (0084). The marks are
/// the users' own (typed chips, or stamped from their diet); this only counts them, and never adds a
/// code nobody marked, beyond what a marked code covers (vegan → vegetarian). Canonical order.
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
            // What a code covers counts too: a vegan line is a vegetarian one (0084's rule).
            let counted = mark.tags.reduce(into: Set(mark.tags)) { $0.formUnion($1.covers) }
            for tag in counted { people[tag, default: []].insert(mark.person) }
        }
        let tags = DietTag.allCases.filter { (people[$0]?.count ?? 0) >= labelPeople }
        var counts: [DietTag: Int] = [:]
        for tag in DietTag.allCases {
            let count = people[tag]?.count ?? 0
            if count > 0 { counts[tag] = count }
        }
        return (tags, DietCounts(counts))
    }
}
