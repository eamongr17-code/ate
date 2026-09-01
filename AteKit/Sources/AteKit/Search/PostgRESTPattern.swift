import Foundation

/// Builds `ilike` patterns out of user-typed text.
///
/// Two hazards this closes, both learned from the legacy build's SQL side (migration 0015 escapes
/// LIKE metacharacters in `search_manual_restaurants` for exactly the same reason):
///
///  1. **LIKE metacharacters.** PostgREST's `ilike` operator has no `ESCAPE` clause, so a literal
///     `%` in the query cannot be escaped on the wire. Typing `"50%"` would otherwise become a
///     wildcard and match the whole table. Metacharacters are therefore rewritten to `_`
///     (match-any-single-character): `"50%"` still finds "50% Off Nights", and also matches "50x",
///     which is a harmless over-match on a capped list — far better than a table scan.
///  2. **PostgREST value parsing.** Unquoted filter values treat `,` `.` `(` `)` as syntax. The
///     whole pattern is double-quoted so a dish called `"Pasta, two ways"` is one value.
enum PostgRESTPattern {
    /// LIKE wildcards plus PostgREST's own `*` alias for `%`.
    static let metacharacters: Set<Character> = ["%", "_", "*", "\\"]

    /// A quoted `%…%` contains-pattern. Returns nil for an empty query.
    static func contains(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return quote("%\(neutralize(trimmed))%")
    }

    /// Rewrites LIKE metacharacters to the single-character wildcard.
    static func neutralize(_ query: String) -> String {
        String(query.map { metacharacters.contains($0) ? "_" : $0 })
    }

    /// Wraps in double quotes, escaping the two characters that are special inside them.
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
