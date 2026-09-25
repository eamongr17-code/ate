import Foundation

/// **Signed out, but looking** — `Welcome`'s "See what everyone's eating", and the one rule that
/// comes with it: reading is free, and the first write asks for sign-in.
///
/// One object, held by the shell and handed to everything that writes, because "asks for sign-in"
/// has to be the same ask whether the write was a bookmark in the feed, the `+`, or Report in the
/// actions sheet (AGENTS.md rule 2). Whoever writes calls ``permitsWrite(_:)`` first; a browser is
/// shown `Welcome` again and the write does not happen.
@MainActor
@Observable
public final class SessionGate {
    /// Why the prompt came up — the funnel's question is which write turns a browser into a person.
    public enum Trigger: String, Sendable, CaseIterable {
        case save
        case compose
        case journal
        case you
        case report
        case block
    }

    /// Looking at the feed with no account.
    public private(set) var isBrowsing = false
    /// `Welcome` is up over the feed, asking.
    public var isAsking = false

    @ObservationIgnored private let analytics: AnalyticsRecorder

    public init(analytics: @escaping AnalyticsRecorder = { _ in }) {
        self.analytics = analytics
    }

    /// "See what everyone's eating".
    public func browse() {
        guard isBrowsing == false else { return }
        isBrowsing = true
        analytics(AccountEvents.browseStarted())
    }

    /// Whether a write may go ahead. A browser is asked to sign in instead, and the write is dropped
    /// rather than queued — replaying a bookmark tapped before a sign-in sheet would save a dish on
    /// behalf of whoever the sheet turned out to belong to.
    public func permitsWrite(_ trigger: Trigger) -> Bool {
        guard isBrowsing else { return true }
        if isAsking == false {
            isAsking = true
            analytics(AccountEvents.signInPrompted(trigger: trigger))
        }
        return false
    }

    /// There is a session now; nothing is asked again.
    public func signedIn() {
        isBrowsing = false
        isAsking = false
    }
}
