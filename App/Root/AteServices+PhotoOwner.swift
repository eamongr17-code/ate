import AteKit
import SwiftUI

extension AteServices {
    /// Whose `Suggestions` dismissals are read — the signed-in person, or the preview drive's one.
    var photoOwner: UUID? {
        isPreviewData ? AteServices.previewOwner : api.currentUserID
    }

    /// Where a list keeps its last first page for the next cold open — the signed-in person's own.
    /// None on the preview drive, whose fixtures must start every launch the same.
    func pageCache(_ list: String) -> EntryPageCache? {
        isPreviewData ? nil : EntryPageCache(list: list, owner: api.currentUserID)
    }
}
