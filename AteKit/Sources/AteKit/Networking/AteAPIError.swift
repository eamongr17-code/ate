import Foundation

/// Errors the API layer raises before or around the transport.
///
/// Transport/PostgREST/Auth errors are passed through untouched — wrapping them would only hide
/// the status code and hint that Sentry wants.
public enum AteAPIError: Error, Equatable, CustomStringConvertible {
    /// A read or write that needs a signed-in user ran without a session. Worth naming explicitly:
    /// RLS on this project is *deny-by-default for anon*, so an unauthenticated read does not fail
    /// — it returns an empty array. Every "the feed is empty" bug starts here.
    case notAuthenticated
    /// A by-id lookup found no row (or the viewer can't see it).
    case notFound(table: String, id: UUID)

    public var description: String {
        switch self {
        case .notAuthenticated:
            "Not signed in. (Anon reads silently return [] under RLS — this is that, caught early.)"
        case .notFound(let table, let id):
            "No visible row in \(table) with id \(id)."
        }
    }
}
