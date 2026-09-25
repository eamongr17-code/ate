import Foundation

/// Builds `ilike` patterns out of user-typed text.
///
/// **LIKE metacharacters** are the hazard this closes, and the only one (migration 0015 escapes them
/// in `search_manual_restaurants` for the same reason): PostgREST's `ilike` operator has no `ESCAPE`
/// clause, so a literal `%` in the query cannot be escaped on the wire. Typing `"50%"` would
/// otherwise become a wildcard and match the whole table. Metacharacters are therefore rewritten to
/// `_` (match-any-single-character): `"50%"` still finds "50% Off Nights", and also matches "50x",
/// which is a harmless over-match on a capped list — far better than a table scan.
///
/// **The pattern is NOT quoted, and must not be.** It used to be, on the theory that PostgREST's
/// reserved characters (`,` `.` `(` `)`) would otherwise break the filter's parsing. They do not:
/// a single `column=ilike.<value>` query parameter runs to the end of the parameter, commas and all.
/// What double quotes *do* inside an `ilike` value is become part of the LIKE pattern — so
/// `ilike."%rot%"` looks for a name that literally starts and ends with a quote character and
/// matches nothing at all. Confirmed against staging (`my_saved_dishes?dish_name=ilike."%rot%"` → 0
/// rows; the same filter unquoted → the saved "Roti"). Quoting belongs to list contexts
/// (`in.(…)`, `or=(…)`), not here.
enum PostgRESTPattern {
    /// LIKE wildcards plus PostgREST's own `*` alias for `%`.
    static let metacharacters: Set<Character> = ["%", "_", "*", "\\"]

    /// A `%…%` contains-pattern. Returns nil for an empty query.
    static func contains(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "%\(neutralize(trimmed))%"
    }

    /// Rewrites LIKE metacharacters to the single-character wildcard.
    static func neutralize(_ query: String) -> String {
        String(query.map { metacharacters.contains($0) ? "_" : $0 })
    }
}
