import AteKit
import SwiftUI

/// What the diary can ask the app to do that isn't reading the diary.
///
/// One value instead of five loose closures on ``DiaryView``'s initialiser, and — more to the point —
/// one place where the composer, the resume row and the first-run link are wired *identically*.
/// The rule the spec keeps returning to is that logging is the same action wherever it is offered
/// (rule 2); a struct makes that a compile-time fact rather than a review comment.
///
/// Nil-able throughout so previews and any host that hasn't wired a door simply doesn't show it,
/// rather than showing one that does nothing.
struct DiaryActions {
    /// Open the log sheet. The origin is the funnel's answer to "where does logging start", so it is
    /// a parameter rather than three separate closures that could drift apart.
    var logDish: (@MainActor (LogCTAOrigin) -> Void)?
    /// Reopen the saved sitting (`LogSheet(entry: .resume)`).
    var resumeDraft: (@MainActor () -> Void)?
    /// Throw the saved sitting away. Sibling of the resume row, never nested inside it.
    var discardDraft: (@MainActor () -> Void)?
    /// Read the current draft, if one is worth offering back. Called on appearance and whenever the
    /// log sheet closes — never per layout pass; it touches the filesystem.
    var loadDraft: (@MainActor () -> LogDraft?)?
    /// Switch to the Feed tab. The only reference to the feed anywhere on the diary (§3.5, §8).
    var showFeed: (@MainActor () -> Void)?

    static let none = DiaryActions()
}
