import AteKit
import Foundation
import SwiftUI
import TipKit

/// **The tips** (`design/rebuild/first-run.html`, steps 8, 9): native TipKit popovers, each
/// on the control it explains, each gone for good once that control is used or its ✕ is tapped. Plus
/// Save on the Feed, and Score and Place on a first entry (`first-post-tips.html`, Eamon 22 Oct).
///
/// Replay onboarding (Settings) bumps an epoch that every tip's `id` carries, so each comes back as
/// a tip TipKit has never seen — its datastore can only be reset before it is configured.
enum AteTips {
    /// At launch. Never under a UI test: a popover over a control would eat the drive's taps.
    static func configure() {
        guard DebugLaunch.isOn(.uiTesting) == false else { return }
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    static var epoch: Int { UserDefaults.standard.integer(forKey: epochKey) }

    /// Every tip, new again — the first-post ones too, until the next entry posts, though the
    /// Journal already holds some.
    static func replay() {
        UserDefaults.standard.set(epoch + 1, forKey: epochKey)
        UserDefaults.standard.set(true, forKey: replaysFirstPostKey)
    }

    /// Entries on the Journal before Lists is worth pointing at: a list needs something to hold.
    static let listsAfterEntries = 5

    private static let epochKey = "ate.tips.epoch"
    private static let replaysFirstPostKey = "ate.tips.replaysFirstPost"
}

/// On the Journal's bell, while the roll holds meals not written up — an empty Journal included, so
/// the bell's count is never unexplained. "More" only once there is an entry for them to be more than.
struct BellTip: Tip {
    var meals: Int
    var hasEntries = true

    var id: String { "tip.bell.\(AteTips.epoch)" }
    var title: Text {
        let more = hasEntries ? " more" : ""
        return Text(meals == 1 ? "1\(more) meal" : "\(meals)\(more) meals")
    }
    var message: Text? { Text("Write them up when you have a minute.") }
}

/// On the Journal | Lists switch, from the fifth entry.
struct ListsTip: Tip {
    var id: String { "tip.lists.\(AteTips.epoch)" }
    var title: Text { Text("Make a list") }
    var message: Text? { Text("Your best burgers, a place to take Mum.") }
}

/// On the Score key, in the composer of a person's first entry (`first-post-tips.html` 1).
struct ScoreTip: Tip {
    var id: String { "tip.score.\(AteTips.epoch)" }
    var title: Text { Text("Score a dish") }
    var message: Text? { Text("Add a rating as you go.") }
}

/// On the Place pill, in a first entry with words and no place, while the tick waits on one
/// (`first-post-tips.html` 2).
struct PlaceTip: Tip {
    var id: String { "tip.place.\(AteTips.epoch)" }
    var title: Text { Text("Add the place") }
    var message: Text? { Text("Where did you go?") }
}

extension AteTips {
    /// Somebody with an entry has written one: neither first-post tip is theirs to see. The Journal
    /// calls this once it holds an entry, and the composer once one posts.
    static func firstPostWritten() {
        ScoreTip().invalidate(reason: .actionPerformed)
        PlaceTip().invalidate(reason: .actionPerformed)
    }

    /// The Journal holds an entry: the first-post tips retire, unless a replay is waiting on the
    /// next entry to post (``firstPostWritten()`` from the composer ends it).
    static func journalHasEntries() {
        guard UserDefaults.standard.bool(forKey: replaysFirstPostKey) == false else { return }
        firstPostWritten()
    }

    /// An entry posted: whatever a replay held back is over.
    static func entryPosted() {
        UserDefaults.standard.removeObject(forKey: replaysFirstPostKey)
        firstPostWritten()
    }
}

/// On the Feed's first dish: the bookmark keeps it on Saved.
struct SaveTip: Tip {
    var id: String { "tip.save.\(AteTips.epoch)" }
    var title: Text { Text("Save a dish") }
    var message: Text? { Text("Tap the bookmark to keep it for later.") }
}
