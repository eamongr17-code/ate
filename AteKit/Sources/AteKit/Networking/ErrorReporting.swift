import Foundation
import Synchronization

/// **Handled errors that should reach Sentry.** Until now Sentry saw crashes only: a journal that
/// would not load or an entry the server refused showed a sentence to the person and told nobody.
///
/// AteKit does not link Sentry. The app installs a sink at launch (`AteApp`), and the stores call
/// ``report(_:where:)`` on their failure paths. What is never sent: a bad connection, a cancelled
/// load, signed out, a row that is gone. Those are the phone or the person, not a fault to fix.
///
/// Volume (50-user beta, Sentry's free 5k errors a month): one report per place and error type per
/// ten minutes from each phone, so a server outage costs one event per phone, not one per retry.
public enum ErrorReporting {
    public typealias Sink = @Sendable (_ error: any Error, _ where: String) -> Void

    private static let state = Mutex<(sink: Sink?, lastSent: [String: Date])>((nil, [:]))
    static let quietPeriod: TimeInterval = 600

    /// Called once at launch with the Sentry call. Tests install a recorder.
    public static func install(_ sink: Sink?) {
        state.withLock { $0 = (sink, [:]) }
    }

    /// Sends `error` unless it is a connection/cancel/auth outcome, or the same kind was sent from
    /// `where` within the quiet period.
    public static func report(_ error: any Error, where place: String, now: Date = Date()) {
        guard isWorthReporting(error) else { return }
        let key = "\(place)|\(String(reflecting: type(of: error)))"
        let sink: Sink? = state.withLock { s in
            guard let sink = s.sink else { return nil }
            if let last = s.lastSent[key], now.timeIntervalSince(last) < quietPeriod { return nil }
            s.lastSent[key] = now
            return sink
        }
        sink?(error, place)
    }

    /// Whether an error is a fault worth a report, not the network or the person.
    public static func isWorthReporting(_ error: any Error) -> Bool {
        if error.isCancellation { return false }
        if error is AteAPIError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .timedOut, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                 .callIsActive, .cancelled, .userAuthenticationRequired:
                return false
            default:
                return true
            }
        }
        return true
    }
}
