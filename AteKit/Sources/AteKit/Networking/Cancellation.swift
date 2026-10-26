import Foundation

public extension Error {
    /// **A read that was called off, not one that failed.** Swift's own `CancellationError`, and the
    /// `URLError.cancelled` a URLSession request throws when the task awaiting it is cancelled — the
    /// shape every Supabase read takes. Neither is "Couldn't reach Ate": nothing went wrong, so a
    /// page says nothing and reads again next time (Eamon's build 239 recording: a pull to refresh
    /// on a place page that SwiftUI called off turned the whole page into the retry state).
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
