import Foundation

/// **"2h", "5h", "1d"** — how old an entry is, in the two or three characters the design gives it.
///
/// A product decision, not a formatter setting: `RelativeDateTimeFormatter` writes "2 hours ago",
/// which is four times the width the artboards draw and a different voice from the app's. So the
/// rule lives here, in AteKit, where the boundaries (59 minutes, a day either side of midnight, a
/// clock that has gone backwards) are covered by tests instead of noticed on a screenshot.
///
/// Everything is floored, never rounded: an entry written 119 minutes ago reads "1h", because it
/// has not been two hours yet and a feed that rounds up is a feed that lies about when you ate.
public enum RelativeAge {
    /// The design's own vocabulary: `now` under a minute, then m, h, d, w, y.
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // A row from the future — a clock skew, or an entry backdated on another device — is not an
        // error worth a screen. It is "now", which is the closest true thing that fits.
        guard seconds >= 60 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }
        return "\(days / 365)y"
    }

    /// The time of day a journal slip prints on the right of its place line: "8:14 pm".
    ///
    /// Stock `.shortened` time, lowercased. The artboards draw 12-hour because that is Melbourne's
    /// default, but the clock a reader has chosen is theirs — a device set to 24 hours prints
    /// "20:14" here, and that is correct rather than a parity miss.
    public static func time(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style).lowercased(with: locale)
    }
}
