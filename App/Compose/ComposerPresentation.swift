import AteKit
import Foundation

/// How the composer was opened, and with what. One value, so a door can never present without the
/// thing it was opened with.
struct ComposerPresentation: Identifiable, Hashable {
    /// Which affordance opened it. A closed set: an unlabelled entry point reads as zero in the
    /// funnel, and `entry_composer_opened(source:)` is the first step of it.
    enum Origin: String, Hashable {
        case tabBar = "tab_bar"
        case journalEmpty = "journal_empty"
        case entryEdit = "entry_edit"
    }

    let id = UUID()
    let origin: Origin
    /// Non-nil when the composer opens on an entry that already exists (editing its words).
    var editing: UUID?
}
