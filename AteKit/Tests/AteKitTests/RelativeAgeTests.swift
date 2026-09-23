import Foundation
import Testing
@testable import AteKit

@Suite("Relative age")
struct RelativeAgeTests {

    private let now = Date(timeIntervalSince1970: 1_789_776_000)

    private func age(secondsAgo: Double) -> String {
        RelativeAge.short(now.addingTimeInterval(-secondsAgo), now: now)
    }

    @Test("Under a minute is 'now' — a feed does not count seconds")
    func underAMinute() {
        #expect(age(secondsAgo: 0) == "now")
        #expect(age(secondsAgo: 59) == "now")
    }

    @Test("Minutes, hours, days, weeks, years")
    func units() {
        #expect(age(secondsAgo: 60) == "1m")
        #expect(age(secondsAgo: 59 * 60) == "59m")
        #expect(age(secondsAgo: 60 * 60) == "1h")
        #expect(age(secondsAgo: 2 * 3600) == "2h")
        #expect(age(secondsAgo: 23 * 3600) == "23h")
        #expect(age(secondsAgo: 24 * 3600) == "1d")
        #expect(age(secondsAgo: 4 * 24 * 3600) == "4d")
        #expect(age(secondsAgo: 7 * 24 * 3600) == "1w")
        #expect(age(secondsAgo: 51 * 7 * 24 * 3600) == "51w")
        #expect(age(secondsAgo: 400 * 24 * 3600) == "1y")
    }

    /// Rounding up would tell somebody they ate two hours ago when they ate an hour and fifty-nine
    /// minutes ago. Everything floors.
    @Test("Every boundary floors")
    func flooring() {
        #expect(age(secondsAgo: 119 * 60) == "1h")
        #expect(age(secondsAgo: 47 * 3600) == "1d")
        #expect(age(secondsAgo: 13 * 24 * 3600) == "1w")
    }

    /// A clock skew, or an entry backdated on another device. Not an error worth a screen.
    @Test("A date in the future reads as now, never as a negative")
    func future() {
        #expect(RelativeAge.short(now.addingTimeInterval(3600), now: now) == "now")
    }

    @Test("The time of day is the reader's own clock, lowercased")
    func timeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        calendar.timeZone = melbourne
        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19,
                                                         hour: 20, minute: 14))!
        let written = RelativeAge.time(evening, locale: Locale(identifier: "en_AU"), timeZone: melbourne)
        // ICU parts the time from its period with a narrow no-break space, so this compares the
        // pieces rather than pinning a separator the platform owns.
        #expect(written.hasPrefix("8:14"))
        #expect(written.hasSuffix("pm"))
        // A device set to 24 hours is not a parity miss — it is the reader's own setting.
        let french = RelativeAge.time(evening, locale: Locale(identifier: "fr_FR"), timeZone: melbourne)
        #expect(french.contains("20"))
    }
}
