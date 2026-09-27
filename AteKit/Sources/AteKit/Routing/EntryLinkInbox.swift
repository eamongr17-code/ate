import Foundation

/// **A link that has arrived, held until the app can open it** (round 5, QA on #83).
///
/// A link can land anywhere: on `Welcome`, halfway through the first-run handle, under the composer,
/// a sheet, the photo preview or the sign-in ask, or on a cold start before any of the shell exists.
/// It is never dropped: it waits here, and each time the shell's situation changes it asks
/// ``next(_:)`` whether now is the moment. The newest link wins — two links open the second.
public struct EntryLinkInbox: Equatable, Sendable {
    /// Where the shell is, as far as a link cares.
    public struct Situation: Equatable, Sendable {
        public var hasSession: Bool
        /// Looking at the feed signed out ("See what everyone's eating").
        public var isBrowsing: Bool
        /// Signed in, on the first-run handle step.
        public var owesHandle: Bool
        /// Something is up over the page that a push would land under: the composer, a sheet, the
        /// photo preview, the sign-in ask. The link waits for it to go.
        public var isCovered: Bool
        /// The tabs and their stacks are on screen — a push made before they are is lost.
        public var isShellUp: Bool

        public init(hasSession: Bool, isBrowsing: Bool, owesHandle: Bool, isCovered: Bool, isShellUp: Bool) {
            self.hasSession = hasSession
            self.isBrowsing = isBrowsing
            self.owesHandle = owesHandle
            self.isCovered = isCovered
            self.isShellUp = isShellUp
        }
    }

    public enum Step: Equatable, Sendable {
        /// Nothing to do yet (or nothing waiting).
        case wait
        /// On `Welcome`: start browsing — reading needs no account (0048). The link keeps waiting,
        /// and opens once the shell is up.
        case browse
        /// Open the entry now.
        case open(UUID)
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
        if situation.hasSession == false, situation.isBrowsing == false { return .browse }
        guard situation.isShellUp else { return .wait }
        pending = nil
        return .open(entryID)
    }
}
