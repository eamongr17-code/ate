import AteKit
import Foundation

/// **Where the share extension's events go** — the same name the app's recorder has, so the shared
/// design-system code (a sheet's `sheet_opened`, a failure alert's `action_failed`) records here
/// unchanged. Nothing leaves the device from the extension: each event is left in the app group's
/// ``ShareInbox`` and the app sends it with its own TelemetryDeck session when it next comes
/// forward. An extension is torn down a second after Save, too soon to trust a network flush.
enum AteTelemetry {
    static let record: AnalyticsRecorder = { event in
        ShareInbox().post(event)
    }
}
