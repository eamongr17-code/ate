#if DEBUG
import AteKit
import SwiftUI

/// Launch arguments that put the composer into a state without a single tap.
///
/// The simulator cannot be typed into from a shell, and a locked screen takes the accessibility path
/// away too — so the states worth looking at have to be reachable from `simctl launch`. Exactly the
/// pattern the design gallery already uses (`-ate-gallery-section`), and Debug only: an installed app
/// has no way to set an argument.
enum ComposerDebugLaunch {
    /// Presents the composer straight from launch.
    static let openArgument = "-ate-open-composer"
    /// Seeds the draft with the design's own sentence, tokens and all.
    static let seedArgument = "-ate-seed-draft"
    /// …and opens the star slider on its first score.
    static let scoringArgument = "-ate-open-scoring"

    static var opensComposer: Bool { has(openArgument) }
    static var opensScoring: Bool { has(scoringArgument) }

    /// Writes the seeded draft before the composer reads it.
    static func seedDraftIfRequested(into drafts: any EntryDraftStoring) {
        guard has(seedArgument) else { return }
        drafts.save(EntryDraft(composition: .previewWordsWithPlace))
    }

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}
#endif
