import Foundation

/// Round 5: somebody else's entry is shared as a link, and a link opens the entry in the app. Built
/// here so the names and parameters are asserted by tests; sent by the app's ``AnalyticsRecorder``.
public enum LinkEvents {
    /// A link to someone else's entry went to the system share sheet. Ids only — never the words.
    public static func entryLinkShared(entryID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_link_shared", parameters: ["entry_id": entryID.uuidString.lowercased()])
    }

    /// A link was opened into the app. `recognised=false` is a URL the app was handed but does not
    /// understand — nothing opened.
    public static func linkOpened(_ link: AteLink?) -> AnalyticsEvent {
        switch link {
        case .entry(let id):
            AnalyticsEvent(name: "link_opened", parameters: [
                "kind": "entry", "entry_id": id.uuidString.lowercased(), "recognised": "true"
            ])
        case .list(let id):
            AnalyticsEvent(name: "link_opened", parameters: [
                "kind": "list", "list_id": id.uuidString.lowercased(), "recognised": "true"
            ])
        case nil:
            AnalyticsEvent(name: "link_opened", parameters: ["recognised": "false"])
        }
    }

    /// Where a bottom sheet's first read had got to when it went up: in hand (`ready`), or still
    /// arriving after ``SheetReadiness/limit`` (`waited`), in which case it opened full height with
    /// still rows. Tells us whether the read-ahead is doing its job.
    public static func sheetOpened(_ sheet: String, ready: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "sheet_opened", parameters: ["sheet": sheet, "ready": ready ? "true" : "false"])
    }
}
