import Foundation

/// **A link that has arrived, held until the app can open it** (round 5, QA on #83).
///
/// A link can land anywhere: on `Welcome`, halfway through the first-run handle, under the composer
/// or the sign-in ask, or on a cold start before any of the shell exists. It is never dropped: it
/// waits here, and each time the shell's situation changes it asks ``next(_:)`` whether now is the
/// moment. The newest link wins — two taps on two links open the second.
public struct EntryLinkInbox: Equatable, Sendable {
    /// Where the shell is, as far as a link cares.
    public struct Situation: Equatable, Sendable {
        public var hasSession: Bool
        /// Looking at the feed signed out ("See what everyone's eating").
        public var isBrowsing: Bool
        /// Signed in, on the first-run handle step.
        public var owesHandle: Bool
        /// Something is up over the shell that a push would land under: the composer, the sign-in
        /// ask. The link waits for it to go.
        public var isCovered: Bool

        public init(hasSession: Bool, isBrowsing: Bool, owesHandle: Bool, isCovered: Bool) {
            self.hasSession = hasSession
            self.isBrowsing = isBrowsing
            self.owesHandle = owesHandle
            self.isCovered = isCovered
        }
    }

    public enum Step: Equatable, Sendable {
        /// Nothing to do yet (or nothing waiting).
        case wait
        /// Open the entry now.
        case open(UUID)
        /// On `Welcome`: start browsing, then open the entry — reading needs no account (0048).
        case browseAndOpen(UUID)
    }

    public private(set) var pending: UUID?

    public init() {}

    /// A link came in. It replaces any still waiting.
    public mutating func receive(_ entryID: UUID) {
        pending = entryID
    }

    /// Whether the waiting link can open now — and if so, it is handed over and no longer waits.
    public mutating func next(_ situation: Situation) -> Step {
        guard let entryID = pending else { return .wait }
        if situation.hasSession, situation.owesHandle { return .wait }
        if situation.isCovered { return .wait }
        pending = nil
        if situation.hasSession == false, situation.isBrowsing == false { return .browseAndOpen(entryID) }
        return .open(entryID)
    }
}
