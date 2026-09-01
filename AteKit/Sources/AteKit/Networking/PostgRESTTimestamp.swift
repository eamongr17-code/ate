import Foundation

/// Formats a `Date` the way a PostgREST filter value must be written.
///
/// **Why this is hand-rolled rather than `ISO8601DateFormatter`:** Postgres `timestamptz` has
/// *microsecond* resolution and the seed rows land on microseconds (`…:25.240956+00:00`).
/// `ISO8601DateFormatter` only emits milliseconds, so a keyset cursor formatted with it would read
/// `…:25.240Z` — and the `created_at.eq.<cursor>` half of the keyset predicate would then match
/// nothing, silently skipping every row whose timestamp sits inside the truncated millisecond.
/// `Date` (a `Double`) holds ~0.2µs resolution at present-day epochs, so rounding to the nearest
/// microsecond reproduces the server value exactly.
///
/// The suffix is `Z`, not `+00:00`, on purpose: `+` is not escaped by `URLComponents` when building
/// a query, so it would reach PostgREST as a space.
enum PostgRESTTimestamp {
    /// `Date.ISO8601FormatStyle` (a Sendable value type) rather than `ISO8601DateFormatter`
    /// (a non-Sendable class that can't be a `static let` under strict concurrency).
    /// Whole seconds in UTC: `2026-08-30T12:30:25Z`.
    private static let secondsStyle = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)

    /// e.g. `2026-08-30T12:30:25.240956Z`
    static func string(from date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = interval.rounded(.down)
        var microseconds = ((interval - seconds) * 1_000_000).rounded()
        if microseconds >= 1_000_000 {  // rounding carried into the next second
            microseconds -= 1_000_000
            seconds += 1
        }
        let base = secondsStyle.format(Date(timeIntervalSince1970: seconds))
        return String(base.dropLast()) + String(format: ".%06dZ", Int(microseconds))  // drop the "Z"
    }
}
