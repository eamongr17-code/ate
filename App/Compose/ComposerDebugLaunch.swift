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
    /// Pushes the newest journal entry, so the entry page and its sheets can be photographed.
    static let entryArgument = "-ate-open-entry"
    /// …with the place sheet or the dish sheet already open on it.
    static let placeSheetArgument = "-ate-open-place-sheet"
    static let dishSheetArgument = "-ate-open-dish-sheet"

    /// A UI-test run starts from nothing. Without this, one test's abandoned draft is the next
    /// test's opening screen — and a drive that depends on what ran before it is not a drive.
    static let uiTestingArgument = "-ate-ui-testing"

    static var isUITesting: Bool { has(uiTestingArgument) }
    static var opensComposer: Bool { has(openArgument) }
    static var opensScoring: Bool { has(scoringArgument) }
    static var opensEntry: Bool { has(entryArgument) }
    static var opensPlaceSheet: Bool { has(placeSheetArgument) }
    static var opensDishSheet: Bool { has(dishSheetArgument) }

    /// Writes the seeded draft before the composer reads it — or wipes whatever a previous run left.
    static func seedDraftIfRequested(into drafts: any EntryDraftStoring) {
        if isUITesting {
            drafts.clear(draftID: drafts.load()?.id)
        }
        guard has(seedArgument) else { return }
        drafts.save(EntryDraft(composition: .previewWordsWithPlace))
    }

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}
#endif
