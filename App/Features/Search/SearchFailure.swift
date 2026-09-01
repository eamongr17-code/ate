import AteKit
import Foundation

/// The three failures the picker treats differently (§11.5).
///
/// The distinction that matters: RLS on this project is deny-by-default for anon, so a signed-out
/// read comes back as an empty array rather than an error. `AteAPIError.notAuthenticated` is what
/// catches that early — and it must surface as "sign in", never as "no results" or a retry button
/// that will never work.
enum SearchFailure: Equatable {
    case signedOut
    case offline
    case failed

    init(_ error: any Error) {
        if let apiError = error as? AteAPIError, apiError == .notAuthenticated {
            self = .signedOut
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotConnectToHost:
                self = .offline
                return
            default:
                break
            }
        }
        self = .failed
    }

    /// Offline and transient failures get the inline "tap to retry" caption; being signed out does not.
    var isRetryable: Bool { self != .signedOut }
}
