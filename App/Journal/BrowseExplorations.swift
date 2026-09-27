import AteKit
import Foundation

/// **Round 4's two browse explorations, behind Debug-only launch arguments.** Each has 2–3 working
/// options for Eamon to pick from; with no argument (and in every shipped build) the app keeps its
/// current behaviour, so an unpicked option can never become the default by merging.
///
/// - `-ate-photo-preview A|B|C` — how a tapped photo opens (``AtePhotoPreviewStyle``).
/// - `-ate-journal-filter A|B` — the journal's filter and sort entry point (``JournalFilterEntry``).
enum BrowseExplorations {
    static let photoPreviewKey = "ate-photo-preview"
    static let journalFilterKey = "ate-journal-filter"

    /// `-ate-photo-preview A` arrives as the `ate-photo-preview` default (the argument domain).
    static var photoPreview: AtePhotoPreviewStyle {
        #if DEBUG
        AtePhotoPreviewStyle(rawValue: value(photoPreviewKey)) ?? .viewer
        #else
        .viewer
        #endif
    }

    static var journalFilter: JournalFilterEntry {
        #if DEBUG
        JournalFilterEntry(rawValue: value(journalFilterKey)) ?? .none
        #else
        .none
        #endif
    }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").uppercased()
    }
}

/// How the journal's filter and sort are reached.
enum JournalFilterEntry: String {
    /// Today's journal: no filter at all.
    case none = ""
    /// A small control beside the Journal | Saved segment, opening a sheet.
    case sheet = "A"
    /// A horizontally scrolling pill row under the segment, each pill its own menu.
    case pillRow = "B"

    /// What `journal_queried` reports as the variant.
    var telemetryName: String {
        switch self {
        case .none: "none"
        case .sheet: "A"
        case .pillRow: "B"
        }
    }
}

extension AteServices {
    /// The journal's filter and sort reads: `my_entries` live, or the contract's in-memory mock under
    /// `-ate-preview-data` — the backend lane lands the RPCs; until then, drives run on the mock.
    var journalQuerying: any JournalQuerying {
        #if DEBUG
        if isPreviewData { return InMemoryJournalQuery(entries: entries) }
        #endif
        return JournalQueryClient(api: api)
    }
}
