import AteKit
import TelemetryDeck

/// The analytics sink for the detail screens. Events are *built* in AteKit (`DetailEvents`, covered
/// by tests) and sent here, because TelemetryDeck is linked into the app target only.
///
/// It's a value, not a singleton call inside the views, so previews and tests can substitute a
/// recorder without a live TelemetryDeck.
enum DetailTelemetry {
    static let live: AnalyticsRecorder = { event in
        TelemetryDeck.signal(event.name, parameters: event.parameters)
    }

    /// Sends nothing. For previews and any Debug drive we don't want in the funnel.
    static let none: AnalyticsRecorder = { _ in }
}
