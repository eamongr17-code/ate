import AteKit
import Foundation
import TelemetryDeck

/// The one place an ``AnalyticsEvent`` leaves the device.
///
/// AteKit builds the events (so their names and parameters are asserted by tests and can never drift
/// silently); this only decides *how* they ship. TelemetryDeck parameters are strings, which is why
/// every event's numbers are already formatted by the time they get here.
enum AteTelemetry {
    static let record: AnalyticsRecorder = { event in
        TelemetryDeck.signal(event.name, parameters: event.parameters)
    }
}
