import Foundation

/// The pure parts of ``SearchStore``: how a next page joins the rows on screen, and how a refusal
/// reads.
extension SearchStore {

    /// Appends a page, dropping anything already on screen — two windows onto one ranked list
    /// overlap by construction (`search_all` has no offset), and a duplicated row is a row a tap
    /// cannot identify.
    static func appending(_ page: SearchRows, to existing: SearchRows) -> SearchRows {
        switch (existing, page) {
        case (.places(let old), .places(let new)):
            var seen = Set(old.map(\.id))
            return .places(old + new.filter { seen.insert($0.id).inserted })
        case (.dishes(let old), .dishes(let new)):
            var seen = Set(old.map(\.dishID))
            return .dishes(old + new.filter { seen.insert($0.dishID).inserted })
        case (.people(let old), .people(let new)):
            var seen = Set(old.map(\.userID))
            return .people(old + new.filter { seen.insert($0.userID).inserted })
        case (.saved(let old), .saved(let new)):
            var seen = Set(old.map(\.dishID))
            return .saved(old + new.filter { seen.insert($0.dishID).inserted })
        default:
            return page
        }
    }

    /// A cancelled request surfaces three ways: Swift's own error, URLSession's, or neither — with the
    /// task simply marked cancelled.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }

    static func failureMessage(_ error: any Error) -> String {
        (error as? AteAPIError) == .notAuthenticated ? "Nobody's\nsigned in." : "Couldn't\nsearch."
    }
}
