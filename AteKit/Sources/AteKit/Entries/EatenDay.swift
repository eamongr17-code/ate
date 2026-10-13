import Foundation

/// **When you ate it** — the composer's date pill (design/rebuild/date-and-photos.html). Date only:
/// the time is kept from the photo or the moment of writing and never shown.
public enum EatenDay {
    /// The chosen day, at the time of day `reference` carries (a photo's, or now). A day picked in
    /// the calendar keeps the entry's own hour, so a dinner moved to Sunday is still a dinner.
    public static func moment(day: Date, keepingTimeOf reference: Date, calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = time.second
        return calendar.date(from: parts) ?? day
    }

    /// Photos from different days: the earliest one's moment. `nil` when none carries a date.
    public static func fromPhotos(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.min()
    }

    /// A photo's EXIF `DateTimeOriginal` ("2026:10:11 19:42:05"), read in its own `OffsetTimeOriginal`
    /// ("+11:00") when the camera wrote one, else in `timeZone` — the phone's, where the photo was
    /// almost certainly taken.
    public static func exifDate(_ value: String, offset: String? = nil, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if let offset, let zone = Self.timeZone(offset: offset) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = timeZone
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces).prefix(19).description)
    }

    /// "+11:00" / "-05:30" → that fixed offset.
    static func timeZone(offset: String) -> TimeZone? {
        let parts = offset.trimmingCharacters(in: .whitespaces)
        guard parts.count == 6, let sign = parts.first, sign == "+" || sign == "-" else { return nil }
        let digits = parts.dropFirst().split(separator: ":")
        guard digits.count == 2, let hours = Int(digits[0]), let minutes = Int(digits[1]) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Never in the future: a moment past `now` (a later hour today, a clock skew) comes back as now.
    public static func clamped(_ date: Date, now: Date = Date()) -> Date {
        min(date, now)
    }

    /// `nil` for today — the pill reads "Today" outlined — else the day as the pill prints it,
    /// "Sun 11 Oct", with the year only when it is not this year's.
    public static func label(for date: Date?, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .current) -> String? {
        guard let date, calendar.isDate(date, inSameDayAs: now) == false else { return nil }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}

/// **The date pill's state**, as the composer holds it: the day, whether the person chose it, and
/// where it came from.
public struct EntryDateChoice: Sendable, Hashable {
    /// `nil` is now: the pill reads Today, and a new entry is dated when it is posted.
    public private(set) var eatenAt: Date?
    /// The person chose the day: photos added afterwards leave it alone.
    public private(set) var isPicked: Bool
    /// Where a new entry's day came from, for `entry_dated`.
    public private(set) var source: EntryDateSource?
    /// What an edit opened on; `nil` for a new entry.
    public let original: Date?

    /// A new entry, or a resumed draft's day.
    public init(eatenAt: Date? = nil, isPicked: Bool = false) {
        self.eatenAt = eatenAt
        self.isPicked = isPicked
        self.source = eatenAt == nil ? nil : (isPicked ? .picked : .photos)
        self.original = nil
    }

    /// An edit: the entry's own moment, already as good as chosen.
    public init(editing createdAt: Date) {
        self.eatenAt = createdAt
        self.isPicked = true
        self.source = nil
        self.original = createdAt
    }

    /// A day from the calendar, at the entry's own time of day (or now's). Today, on a new entry,
    /// is the default again.
    public mutating func pick(_ day: Date, now: Date = Date(), calendar: Calendar = .current) {
        let moment = EatenDay.clamped(
            EatenDay.moment(day: day, keepingTimeOf: eatenAt ?? now, calendar: calendar), now: now
        )
        isPicked = true
        if original == nil, calendar.isDate(moment, inSameDayAs: now) {
            eatenAt = nil
            source = nil
        } else {
            eatenAt = moment
            source = .picked
        }
    }

    /// Photos bring their own day (the earliest of them) to a new entry the person has not dated
    /// themselves. Today's photos change nothing. Answers whether the day moved.
    @discardableResult
    public mutating func photosDated(_ dates: [Date?], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard original == nil, isPicked == false, let earliest = EatenDay.fromPhotos(dates) else { return false }
        guard let moment = [eatenAt, earliest].compactMap({ $0 }).min(),
              calendar.isDate(moment, inSameDayAs: now) == false, moment != eatenAt else { return false }
        eatenAt = EatenDay.clamped(moment, now: now)
        source = .photos
        return true
    }

    /// An edit moved the day.
    public var changed: Bool {
        guard let original, let eatenAt else { return false }
        return abs(eatenAt.timeIntervalSince(original)) >= 1
    }

    /// What the calendar opens on.
    public func calendarDay(now: Date = Date()) -> Date { eatenAt ?? now }

    /// What the pill prints: `nil` reads Today.
    public func label(now: Date = Date()) -> String? { EatenDay.label(for: eatenAt, now: now) }

    /// Whole calendar days back from `now`, for `entry_dated`.
    public func daysAgo(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let eatenAt else { return 0 }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: eatenAt), to: calendar.startOfDay(for: now)
        ).day
        return max(0, days ?? 0)
    }
}
