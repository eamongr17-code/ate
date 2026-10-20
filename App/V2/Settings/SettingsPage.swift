import AteKit
import SwiftUI

/// The pages of the settings branch. One `Route` case carries this, so the shell learns one new
/// destination rather than five.
enum SettingsPage: Hashable {
    /// `Settings.dc.html` itself.
    case root
    /// `Handle.dc.html`, reached from the Handle row — the same screen as first run, with a way back.
    /// Carries the handle the row was showing, so the field opens on it rather than on nothing.
    case handle(current: String?)
    /// Appearance: System / Light / Dark.
    case appearance
    /// Diet: the five codes, a tick list you can pick several in (`design/rebuild/diet.html`).
    case diet
    /// Blocked people.
    case blocked
    /// The privacy policy, in the app (``LegalDocument/privacy``).
    case privacy
    /// The terms, in the app (``LegalDocument/terms``).
    case terms
}
