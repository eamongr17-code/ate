import Foundation
import Testing
@testable import AteKit

/// The artboard's own three rows — "Friday night", "Last Sunday", "12 September" — plus the grouping
/// rule underneath them.
@Suite("Photo suggestions")
struct PhotoSuggestionsTests {
    /// Friday 19 September 2025, 21:40 — the artboard's first row.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }()

    private func date(_ day: Int, _ month: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Photos within two hours are one sitting")
    func groupsBySitting() {
        let items = [
            PhotoSuggestionItem(id: "a", createdAt: date(19, 9, 20, 10)),
            PhotoSuggestionItem(id: "b", createdAt: date(19, 9, 21, 40)),
            PhotoSuggestionItem(id: "c", createdAt: date(14, 9, 13, 15))
        ]
        let clusters = PhotoSuggestions.cluster(items, now: date(21, 9, 12))
        #expect(clusters.count == 2)
        #expect(clusters[0].items.map(\.id) == ["a", "b"])
        #expect(clusters[1].items.map(\.id) == ["c"])
    }

    @Test("A gap longer than two hours starts a new sitting")
    func splitsOnGap() {
        let items = [
            PhotoSuggestionItem(id: "a", createdAt: date(19, 9, 12)),
            PhotoSuggestionItem(id: "b", createdAt: date(19, 9, 20))
        ]
        #expect(PhotoSuggestions.cluster(items, now: date(20, 9, 9)).count == 2)
    }

    @Test("A sitting offers at most the composer's five")
    func capsAtFive() {
        let items = (0..<8).map {
            PhotoSuggestionItem(id: "\($0)", createdAt: date(19, 9, 20, $0 * 5))
        }
        let clusters = PhotoSuggestions.cluster(items, now: date(20, 9, 9))
        #expect(clusters.count == 1)
        #expect(clusters[0].items.count == 5)
    }

    @Test("Newest sitting first, and its id is its first photo")
    func ordersNewestFirst() {
        let items = [
            PhotoSuggestionItem(id: "old", createdAt: date(12, 9, 20)),
            PhotoSuggestionItem(id: "new", createdAt: date(19, 9, 20))
        ]
        let clusters = PhotoSuggestions.cluster(items, now: date(20, 9, 9))
        #expect(clusters.map(\.id) == ["new", "old"])
    }

    @Test("Photos older than the window are not suggested")
    func dropsOldPhotos() {
        let items = [PhotoSuggestionItem(id: "ancient", createdAt: date(1, 1, 12))]
        #expect(PhotoSuggestions.cluster(items, now: date(20, 9, 9)).isEmpty)
    }

    @Test("The artboard's three titles")
    func titles() {
        let now = date(21, 9, 12)  // Sunday 21 September 2025
        #expect(PhotoSuggestions.title(for: date(19, 9, 21, 40), now: now,
                                       calendar: calendar, locale: calendar.locale!) == "Friday night")
        #expect(PhotoSuggestions.title(for: date(14, 9, 13, 15), now: now,
                                       calendar: calendar, locale: calendar.locale!) == "Last Sunday")
        #expect(PhotoSuggestions.title(for: date(12, 9, 20, 2), now: now,
                                       calendar: calendar, locale: calendar.locale!) == "12 September")
    }

    @Test("Today and yesterday are named as such")
    func recentTitles() {
        let now = date(21, 9, 22)
        #expect(PhotoSuggestions.title(for: date(21, 9, 20), now: now,
                                       calendar: calendar, locale: calendar.locale!) == "Night")
        #expect(PhotoSuggestions.title(for: date(20, 9, 13), now: now,
                                       calendar: calendar, locale: calendar.locale!) == "Yesterday lunch")
    }

    @Test("The clock is the artboard's lowercase")
    func clock() {
        #expect(PhotoSuggestions.time(for: date(19, 9, 21, 40), calendar: calendar,
                                      locale: Locale(identifier: "en_AU")) == "9:40 pm")
    }
}
