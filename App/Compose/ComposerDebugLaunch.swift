#if DEBUG
import AteKit
import SwiftUI

/// **The composer, and the entry page it lands on, put into a state without a single tap.**
///
/// The simulator cannot be typed into from a shell, and a locked screen takes the accessibility path
/// away too — so the states worth looking at are reached from the launch instead (``DebugLaunch``):
/// `-ate-open composer?score`, `composer?caret`, `composer?camera`, `composer?capture`,
/// `entry/<id>?sheet=place|dish|share`, `…&add-place`, and the `draft` fixture. Debug only: an
/// installed app has no way to set an argument.
enum ComposerDebugLaunch {
    /// Holds the sort back after Post (``DebugLaunch/Flag/slowSort``).
    static let slowSortDelay: Duration = .seconds(6)
    /// Holds "Posting…" up to 8s rather than 3.5, so a drive's taps all land inside the hold (with
    /// the slow sort, the sort answers at 6s — still inside it).
    static var postHold: PostHold { DebugLaunch.isOn(.longHold) ? PostHold(maximum: .seconds(8)) : .standard }

    static var slowsSort: Bool { DebugLaunch.isOn(.slowSort) }
    static var drivesUndo: Bool { DebugLaunch.isOn(.undoDrive) }
    static var opensComposer: Bool { DebugLaunch.route?.screen == .composer }
    static var opensScoring: Bool { DebugLaunch.has(.score) }
    /// Parks the caret straight after the seeded draft's first score pill — the place Eamon saw the
    /// caret drawn wrong, and not one a shell can tap to.
    static var parksCaretAfterToken: Bool { DebugLaunch.has(.caret) }
    static var fakesCameraCapture: Bool { DebugLaunch.has(.capture) }
    static var fakesCameraCover: Bool { DebugLaunch.has(.camera) }
    static var opensAddPlace: Bool { DebugLaunch.has(.addPlace) }
    static var opensPlaceSheet: Bool { DebugLaunch.route?.value(.sheet) == "place" }
    static var opensDishSheet: Bool { DebugLaunch.route?.value(.sheet) == "dish" }
    static var opensShare: Bool { DebugLaunch.route?.value(.sheet) == "share" }

    /// Writes the seeded draft before the composer reads it — or wipes whatever a previous run left.
    static func seedDraftIfRequested(into drafts: any EntryDraftStoring) {
        if DebugLaunch.isOn(.uiTesting) {
            drafts.clear(draftID: drafts.load()?.id)
        }
        guard DebugLaunch.has(.draft) else { return }
        // `ComposerPlaceB`: the words, and Tipo 00 on the Place key rather than in them. The seed
        // place default (``DebugLaunch/seedPlaceKey``) puts a different name on the key — the
        // long-name truncation.
        let placeName = UserDefaults.standard.string(forKey: DebugLaunch.seedPlaceKey) ?? "Tipo 00"
        var draft = EntryDraft(composition: .previewComposerWords, restaurantID: tipoID, placeName: placeName)
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
}
#endif
