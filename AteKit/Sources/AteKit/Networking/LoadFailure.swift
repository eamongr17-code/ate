import Foundation

/// **Why something could not be shown** — the two failures a reader can tell apart, and must.
///
/// "Couldn't reach Ate" is the phone or the server: offline, a timeout, a 500. It is temporary, and
/// it gets a retry. "Gone" is the thing itself: deleted, or its author blocked — no row the viewer
/// can see. A retry there would be a button that never works, so it gets none.
public enum LoadFailure: Sendable, Equatable {
    case unreachable
    case gone

    public init(_ error: any Error) {
        if case .notFound = error as? AteAPIError {
            self = .gone
        } else {
            self = .unreachable
        }
    }
}
