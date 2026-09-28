import AteKit
import Foundation

/// **What a pushed page may ask of the shell** — handed to ``Route/destination(_:)``, so each page is
/// built in its own feature folder and a new one never has to reach into `App/Root`.
///
/// Built fresh for every destination (the shell's body re-evaluates them), so the values in it are
/// always the current ones.
@MainActor
struct RouteContext {
    let services: AteServices
    /// The one save, made once and handed down.
    let saves: SaveAction
    /// Where this page was opened from — the `source` its view event carries.
    let source: DetailSource
    /// The handle a receipt is signed with — read only by a page that signs one.
    let handle: () -> String
    /// Pushes a page, labelled with where it was opened from.
    let push: (Route, DetailSource) -> Void
    /// Presents the composer.
    let compose: (ComposerPresentation) -> Void
    /// An entry changed under a page: the journal and the feed behind it catch up.
    let entryChanged: (EntryCard) -> Void
    /// Somebody was blocked. Their page comes off the stack — or, from an entry page (`nil`), the
    /// whole stack — and the feed forgets them.
    let blocked: (_ userID: UUID?) -> Void
    /// A `Suggestions` sitting was dismissed: the journal header's count changes.
    let photosChanged: () -> Void
    /// A new handle from Settings.
    let handleChanged: (String) -> Void
    /// Signed out (`nil`), or the account deleted (whose, when known): the session is over.
    let endSession: (_ deleted: UUID?) -> Void

    func open(_ route: Route, from source: DetailSource = .unknown) {
        push(route, source)
    }
}
