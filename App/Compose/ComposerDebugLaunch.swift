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
    /// Pushes the place, and the dish, of the first feed entry that has one — the only way a drive
    /// photographs those two pages on a simulator that cannot be tapped from a shell.
    static let placeArgument = "-ate-open-place"
    static let dishArgument = "-ate-open-dish"
    /// The Summary after Done, printed — or, with ``summaryPrintingArgument``, still printing.
    static let summaryArgument = "-ate-open-summary"
    static let summaryPrintingArgument = "-ate-summary-printing"
    /// …or written with no place, so its receipt waits on the Place key.
    static let summaryNoPlaceArgument = "-ate-summary-no-place"

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

    /// Parks the caret straight after the seeded draft's first score pill — the place Eamon saw the
    /// caret drawn wrong, and not one a shell can tap to.
    static let caretAfterTokenArgument = "-ate-caret-after-token"

    /// Opens `ComposerVoice` over the composer, on a draft holding the artboard's opening words.
    static let voiceArgument = "-ate-open-voice"
    /// Dictation from a script instead of a microphone (``FakeVoiceTranscriber``) — the simulator has
    /// none. Implied by ``voiceArgument``.
    static let fakeDictationArgument = "-ate-fake-dictation"
    /// …and refuses, for the permission-denied state.
    static let denyDictationArgument = "-ate-deny-dictation"
    /// A camera capture without a camera: the artboard's ragù lands through the camera key's own path.
    static let fakeCameraArgument = "-ate-fake-camera"

    /// Lets the scripted dictation finish, closes the microphone, then runs the text view's own undo —
    /// and, with ``voiceRedoArgument``, its redo. The one way to watch "undo across a dictation" on a
    /// machine that can neither talk nor shake.
    static let voiceUndoArgument = "-ate-voice-undo"
    static let voiceRedoArgument = "-ate-voice-redo"

    static var isUITesting: Bool { has(uiTestingArgument) }
    static var drivesVoiceUndo: Bool { has(voiceUndoArgument) || has(voiceRedoArgument) }
    static var drivesVoiceRedo: Bool { has(voiceRedoArgument) }
    static var opensVoice: Bool { has(voiceArgument) }
    static var fakesDictation: Bool { has(fakeDictationArgument) || has(voiceArgument) }
    static var deniesDictation: Bool { has(denyDictationArgument) }
    static var fakesCameraCapture: Bool { has(fakeCameraArgument) }
    static var parksCaretAfterToken: Bool { has(caretAfterTokenArgument) }
    static var drivesUndo: Bool { has(undoDriveArgument) }
    static var opensComposer: Bool { has(openArgument) || has(voiceArgument) || has(fakeCameraArgument) }
    static var opensScoring: Bool { has(scoringArgument) }
    static var opensEntry: Bool { has(entryArgument) || has(shareArgument) }
    static var opensPlaceSheet: Bool { has(placeSheetArgument) }
    static var opensDishSheet: Bool { has(dishSheetArgument) }
    static var opensSuggestions: Bool { has(suggestionsArgument) }
    static var opensWelcome: Bool { has(welcomeArgument) }
    static var opensAddPlace: Bool { has(addPlaceArgument) }
    static var opensFeed: Bool {
        has(feedArgument) || has(profileArgument) || has(placeArgument) || has(dishArgument)
    }
    static var opensSaved: Bool { has(savedArgument) }
    static var opensProfile: Bool { has(profileArgument) }
    static var opensYou: Bool { has(youArgument) || has(ratingsArgument) || has(recapArgument) }
    static var opensRatings: Bool { has(ratingsArgument) }
    static var opensRecap: Bool { has(recapArgument) }
    static var opensShare: Bool { has(shareArgument) }
    static var opensPlace: Bool { has(placeArgument) }
    static var opensSummary: Bool {
        has(summaryArgument) || has(summaryPrintingArgument) || has(summaryNoPlaceArgument)
    }
    static var summaryPrints: Bool { has(summaryPrintingArgument) }
    static var summaryHasNoPlace: Bool { has(summaryNoPlaceArgument) }
    static var opensDish: Bool { has(dishArgument) }

    /// Writes the seeded draft before the composer reads it — or wipes whatever a previous run left.
    static func seedDraftIfRequested(into drafts: any EntryDraftStoring) {
        if isUITesting {
            drafts.clear(draftID: drafts.load()?.id)
        }
        if has(voiceArgument), has(seedArgument) == false {
            // `ComposerVoice.dc.html` opens on the words typed before the microphone — "With Jess
            // for her birthday." — the rest is what gets said. The place is on the key.
            drafts.save(EntryDraft(composition: .voiceOpeningWords, restaurantID: tipoID, placeName: "Tipo 00"))
            return
        }
        guard has(seedArgument) else { return }
        // `ComposerPlaceB`: the words, and Tipo 00 on the Place key rather than in them.
        var draft = EntryDraft(composition: .previewComposerWords, restaurantID: tipoID, placeName: "Tipo 00")
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

    /// The preview directory's Tipo 00, so a seeded draft's place resolves to the real fixture.
    private static let tipoID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}

extension EntryComposition {
    /// `ComposerVoice.dc.html`'s words before anybody spoke — the place is on the key now.
    static var voiceOpeningWords: EntryComposition {
        EntryComposition(plain: "With Jess for her birthday.", spans: [])
    }
}
#endif
