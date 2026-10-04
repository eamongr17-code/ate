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
    /// How Ate uses AI.
    case artificialIntelligence
    /// Blocked people.
    case blocked
    /// The component kit's gallery — Debug and Beta builds only, from a row at Settings' foot.
    case kit
}
