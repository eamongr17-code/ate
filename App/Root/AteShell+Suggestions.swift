import AteKit
import SwiftUI

/// **`Suggestions`, and the journal header's count of it** — out of the shell's own file so the
/// shell stays a shell.
extension AteShell {

    /// `Suggestions.dc.html`: the page, wired to the composer it opens and the badge it changes.
    var suggestions: some View {
        SuggestionsScreen(
            library: services.photos,
            owner: photoOwner,
            analytics: services.analytics,
            onWrite: { cluster in
                composing = ComposerPresentation(
                    origin: .photoSuggestion,
                    assetIdentifiers: cluster.items.map(\.id)
                )
            },
            onDismissed: { Task { await countPhotos() } }
        )
    }

    /// The header badge. Reads the camera roll only when it has already been allowed — the ask
    /// belongs to `Suggestions`, and a launch that asks for photos is exactly what the design's
    /// "nothing is ever assumed" rule is against. Less every photo a `Suggestions` X dismissed: a
    /// dismissed sitting is gone from the badge too, for good.
    func countPhotos() async {
        guard services.photos.isAuthorized else { return }
        let dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: photoOwner)
        photoCount = dismissals.count(await services.photos.recent())
    }

    /// Whose `Suggestions` dismissals are read — the signed-in person, or the preview drive's one.
    private var photoOwner: UUID? {
        services.isPreviewData ? AteServices.previewOwner : services.api.currentUserID
    }
}
