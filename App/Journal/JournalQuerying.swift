import AteKit
import Foundation

extension AteServices {
    /// The journal's filter and sort reads: `my_entries` and `my_entry_places` (0043), live on
    /// staging. Under `-ate-preview-data` — a drive with no backend at all — the contract's
    /// in-memory mock answers instead.
    var journalQuerying: any JournalQuerying {
        #if DEBUG
        if isPreviewData { return InMemoryJournalQuery(entries: entries) }
        #endif
        return JournalQueryClient(api: api)
    }
}
