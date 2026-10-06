import AteKit
import Foundation
import SwiftUI
import TipKit

/// **The three tips** (`design/rebuild/first-run.html`, steps 6, 8, 9): native TipKit popovers, each
/// on the control it explains, each gone for good once that control is used or its ✕ is tapped. Plus
/// Save on the Feed. Words are the tips' only words; there is no tour.
///
/// Replay first run (Settings, Debug and Beta) bumps an epoch that every tip's `id` carries, so each
/// comes back as a tip TipKit has never seen — its datastore can only be reset before it is configured.
enum AteTips {
    /// At launch. Never under a UI test: a popover over a control would eat the drive's taps.
    static func configure() {
        guard DebugLaunch.isOn(.uiTesting) == false else { return }
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    static var epoch: Int { UserDefaults.standard.integer(forKey: epochKey) }

    /// Every tip, new again.
    static func replay() {
        UserDefaults.standard.set(epoch + 1, forKey: epochKey)
    }

    /// Entries on the Journal before Lists is worth pointing at: a list needs something to hold.
    static let listsAfterEntries = 5

    private static let epochKey = "ate.tips.epoch"
}

/// On the composer's Score key: the inline score is the one thing Ate does that nothing else does.
struct ScoreTip: Tip {
    var id: String { "tip.score.\(AteTips.epoch)" }
    var title: Text { Text("Score as you write") }
    var message: Text? { Text("Name a dish, then tap Score.") }
}

/// On the Journal's bell, once there is an entry and the roll holds more meals.
struct BellTip: Tip {
    var meals: Int

    var id: String { "tip.bell.\(AteTips.epoch)" }
    var title: Text { Text(meals == 1 ? "1 more meal" : "\(meals) more meals") }
    var message: Text? { Text("Write them up when you have a minute.") }
}

/// On the Journal | Lists switch, from the fifth entry.
struct ListsTip: Tip {
    var id: String { "tip.lists.\(AteTips.epoch)" }
    var title: Text { Text("Make a list") }
    var message: Text? { Text("Your best burgers, a place to take Mum.") }
}

/// On the Feed's first dish: the bookmark keeps it on Saved.
struct SaveTip: Tip {
    var id: String { "tip.save.\(AteTips.epoch)" }
    var title: Text { Text("Save a dish") }
    var message: Text? { Text("Tap the bookmark to keep it for later.") }
}
