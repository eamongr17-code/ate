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
    /// Pushes `Suggestions` from the journal's header.
    static let suggestionsArgument = "-ate-open-suggestions"
    /// Opens a tab, or a shelf, or somebody's profile, straight from launch — the only way a drive
    /// reaches a screen on a simulator that cannot be tapped from a shell.
    static let feedArgument = "-ate-open-feed"
    static let savedArgument = "-ate-open-saved"
    /// …and pushes the first feed author's page on top of the feed.
    static let profileArgument = "-ate-open-profile"
    /// The You tab, and the two pages that hang off it.
    static let youArgument = "-ate-open-you"
    static let ratingsArgument = "-ate-open-ratings"
    static let recapArgument = "-ate-open-recap"
    /// …and `Share`, on an entry's receipt. Implies ``entryArgument`` — `Share` is presented FROM
    /// an entry page, so asking for it on its own has to open one.
    static let shareArgument = "-ate-open-share"

    /// Shows `Welcome` even when this build has a session — the one screen you cannot reach once
    /// you are signed in.
    static let welcomeArgument = "-ate-open-welcome"
    /// …and `AddPlace` on top of the place sheet.
    static let addPlaceArgument = "-ate-open-add-place"

    /// A UI-test run starts from nothing. Without this, one test's abandoned draft is the next
    /// test's opening screen — and a drive that depends on what ran before it is not a drive.
    static let uiTestingArgument = "-ate-ui-testing"

    /// Puts two buttons in the composer's header that run the text view's own undo and redo.
    ///
    /// Undo on a phone is a shake or a three-finger swipe, and XCUITest can drive neither; Cmd+Z
    /// needs a hardware keyboard, which hides the software keyboard another test asserts. So the
    /// crash path — UIKit's own undo operations, run after a programmatic edit — is reached through
    /// this instead. Debug *and* behind an argument, so it does not exist in any build anyone runs.
    static let undoDriveArgument = "-ate-undo-drive"

    static var isUITesting: Bool { has(uiTestingArgument) }
    static var drivesUndo: Bool { has(undoDriveArgument) }
    static var opensComposer: Bool { has(openArgument) }
    static var opensScoring: Bool { has(scoringArgument) }
    static var opensEntry: Bool { has(entryArgument) || has(shareArgument) }
    static var opensPlaceSheet: Bool { has(placeSheetArgument) }
    static var opensDishSheet: Bool { has(dishSheetArgument) }
    static var opensSuggestions: Bool { has(suggestionsArgument) }
    static var opensWelcome: Bool { has(welcomeArgument) }
    static var opensAddPlace: Bool { has(addPlaceArgument) }
    static var opensFeed: Bool { has(feedArgument) || has(profileArgument) }
    static var opensSaved: Bool { has(savedArgument) }
    static var opensProfile: Bool { has(profileArgument) }
    static var opensYou: Bool { has(youArgument) || has(ratingsArgument) || has(recapArgument) }
    static var opensRatings: Bool { has(ratingsArgument) }
    static var opensRecap: Bool { has(recapArgument) }
    static var opensShare: Bool { has(shareArgument) }

    /// Writes the seeded draft before the composer reads it — or wipes whatever a previous run left.
    static func seedDraftIfRequested(into drafts: any EntryDraftStoring) {
        if isUITesting {
            drafts.clear(draftID: drafts.load()?.id)
        }
        guard has(seedArgument) else { return }
        var draft = EntryDraft(composition: .previewWordsWithPlace)
        // …with the artboard's own three photos already staged, so `Composer` can be photographed
        // as it is drawn rather than one cluster short of it.
        draft.photoFiles = seedPhotos(into: drafts.photoDirectory(for: draft.id))
        drafts.save(draft)
    }

    private static func seedPhotos(into directory: URL) -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ["ragu", "prawn", "tiramisu"].compactMap { name in
            guard let image = UIImage(named: "Photos/\(name)"),
                  let data = image.jpegData(compressionQuality: 0.8) else { return nil }
            let fileName = "\(name).jpg"
            try? data.write(to: directory.appending(path: fileName), options: .atomic)
            return fileName
        }
    }

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}
#endif
