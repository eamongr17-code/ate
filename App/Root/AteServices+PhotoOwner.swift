import AteKit
import SwiftUI

extension AteServices {
    /// Whose `Suggestions` dismissals are read — the signed-in person, or the preview drive's one.
    var photoOwner: UUID? {
        isPreviewData ? AteServices.previewOwner : api.currentUserID
    }
}
