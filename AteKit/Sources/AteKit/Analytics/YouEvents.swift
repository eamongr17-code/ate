import Foundation

/// **What you gave back** — the You tab's funnel, built here so the names and parameters are
/// asserted by tests and can never drift, and sent by the app target's ``AnalyticsRecorder``.
///
/// `you_viewed → ratings_viewed → statement_viewed` is the "does anyone come back for the record"
/// question PRODUCT.md asks; `receipt_shared` (``EntryEvents/receiptShared(entryID:source:)``) is the
/// north-star event this branch feeds, which is why the statement's share goes out under that name
/// and not a second one.
public enum YouEvents {

    /// The You tab became visible. Once per appearance, not once per read.
    public static func youViewed() -> AnalyticsEvent {
        AnalyticsEvent(name: "you_viewed")
    }

    /// A histogram bar was opened. `score` is the bar, one decimal — the shape of the answer is
    /// "which scores do people actually go back and look at".
    public static func ratingsViewed(score: Double) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "ratings_viewed",
            parameters: ["score": invariant(ScoreHistogram.snapped(score))]
        )
    }

    /// A statement was read. `month` is `YYYY-MM`, so a month reads the same in every time zone.
    public static func statementViewed(month: StatementMonth) -> AnalyticsEvent {
        AnalyticsEvent(name: "statement_viewed", parameters: ["month": month.key])
    }

    /// A number as an analytics parameter: one decimal, **always a period, never a comma**.
    ///
    /// ``ScoreFormat`` is a *display* formatter and follows the reader's locale — on `de_DE` it
    /// writes `4,5`. A dashboard groups on the string, so a locale-aware parameter silently splits
    /// one bar into two series and the German half of the answer goes missing. Every other numeric
    /// parameter in the funnel is an `Int` through `String(_:)`, which has the same property for
    /// free; a `Double` has to say so.
    static func invariant(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(1))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}
