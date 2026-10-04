import AteKit
import SwiftUI

/// **The journal header's count of `Suggestions`** — out of the shell's own file so the shell stays
/// a shell. The page itself is `SuggestionsScreen`'s (`App/Journal`).
extension AteShell {

    /// The header badge. Reads the camera roll only when it has already been allowed — the ask
    /// belongs to `Suggestions`, and a launch that asks for photos is exactly what the design's
    /// "nothing is ever assumed" rule is against. Less every photo a `Suggestions` X dismissed: a
    /// dismissed sitting is gone from the badge too, for good.
    func countPhotos() async {
        guard services.photos.isAuthorized else { return }
        let dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: services.photoOwner)
        photoCount = dismissals.count(await services.photos.recent())
    }
}
