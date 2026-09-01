import Foundation

/// Where a detail screen's first load has got to. Deliberately four cases, not a pile of booleans:
/// `loading && loaded && failed` is unrepresentable.
public enum DetailLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool { self == .loading }
    public var isLoaded: Bool { self == .loaded }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

extension Error {
    /// What a detail screen shows when a read fails. Nothing clever: the localized description,
    /// which is the network/PostgREST message the user (and a screenshot in a bug report) can act on.
    var detailDisplayMessage: String { localizedDescription }
}
