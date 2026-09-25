import Foundation

/// **The Search tab's two events.**
///
/// Deliberately not ``SearchEvent`` (the composer picker's funnel, `SearchTelemetry.swift`): that one
/// is keyed on ``SearchSubject`` — what a *pick* is choosing — and it cannot say "people" or "saved"
/// at all. Two surfaces, two questions: the picker's events ask "did they find the place they were
/// logging", these ask "what are people looking for in the app, and does it answer them".
///
/// Sent through the app's one ``AnalyticsRecorder``, like every other screen's events.
public enum SearchEvents {

    /// A completed, debounced, non-stale query. Fired once per query, not once per page — depth is
    /// what `result_count` is for.
    ///
    /// The standing lists (Nearby, your whole shelf) are NOT searches and are not counted: nobody
    /// typed anything, and a zero-length query in the length distribution makes the median a lie.
    public static func searchPerformed(
        scope: SearchScope,
        queryLength: Int,
        resultCount: Int,
        milliseconds: Int? = nil
    ) -> AnalyticsEvent {
        var parameters = [
            "scope": scope.telemetryName,
            "query_length": String(max(0, queryLength)),
            "result_count": String(max(0, resultCount))
        ]
        if let milliseconds { parameters["ms"] = String(max(0, milliseconds)) }
        return AnalyticsEvent(name: "search_performed", parameters: parameters)
    }

    /// A result row was opened. At the tap, and only the scope: which row it was is the place or
    /// dish page's own `*_viewed(source: search)`, which already exists.
    public static func searchResultOpened(scope: SearchScope) -> AnalyticsEvent {
        AnalyticsEvent(name: "search_result_opened", parameters: ["scope": scope.telemetryName])
    }
}
