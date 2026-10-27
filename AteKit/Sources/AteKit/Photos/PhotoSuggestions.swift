import Foundation

/// One photo in the library, reduced to what a suggestion needs: its identity, when it was taken,
/// and where, if the photo says (`PHAsset.location`; no extra permission).
public struct PhotoSuggestionItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    /// Where it was taken. Only ever used to OFFER nearby places as chips; never attached by itself.
    public let coordinate: PhotoCoordinate?

    public init(id: String, createdAt: Date, coordinate: PhotoCoordinate? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.coordinate = coordinate
    }
}

/// **A sitting, guessed from the camera roll.** Photos taken close together are one meal; the person
/// writes about it or they don't.
public struct PhotoSuggestionCluster: Identifiable, Equatable, Sendable {
    /// The photos it offers — the row's, and exactly the ones the composer opens holding.
    public let items: [PhotoSuggestionItem]
    /// The rest of the sitting: retakes of a shot already offered, and photos past the limit. Never
    /// offered, but they go with the sitting when it is dismissed, or they would come back as a new one.
    public let others: [PhotoSuggestionItem]

    public init(items: [PhotoSuggestionItem], others: [PhotoSuggestionItem] = []) {
        self.items = items
        self.others = others
    }

    /// The first photo's identity — stable across a re-fetch, unlike a position in a list.
    public var id: String { items.first?.id ?? "" }
    /// When the sitting started.
    public var date: Date { items.first?.createdAt ?? .distantPast }
    /// Where the sitting was, from its first photo that carries a location. `nil` = no chips.
    public var coordinate: PhotoCoordinate? { items.lazy.compactMap(\.coordinate).first }
}

/// **`Suggestions`** — recent photos, grouped into sittings and named the way a person would name
/// them ("Friday night", "Last Sunday", "12 September").
///
/// Pure, and tested against the artboard's own three rows. Design rule 8 is not touched here: a
/// cluster carries photos, a time and at most a coordinate, and **never a place** — a place reaches
/// the composer only when the person taps one of the nearby chips (``PhotoPlaceChips``).
public enum PhotoSuggestions {
    /// How many photos one cluster offers: the three its row shows, so the composer opens holding
    /// exactly what was seen. (It took five, two of them never shown: 27 Oct, a mezze plate five times.)
    public static let photoLimit = 3
    /// A photo taken this soon after the last one offered is a retake of the same shot, not another
    /// dish: three frames of one plate are offered once.
    public static let sameShot: TimeInterval = 10
    /// A new photo more than this long after the last one starts a new sitting.
    public static let gap: TimeInterval = 2 * 60 * 60
    /// How far back the screen looks.
    public static let window: TimeInterval = 21 * 24 * 60 * 60

    /// Groups photos into sittings, newest first. Input may be in any order.
    public static func cluster(
        _ items: [PhotoSuggestionItem],
        now: Date = Date(),
        gap: TimeInterval = PhotoSuggestions.gap
    ) -> [PhotoSuggestionCluster] {
        sittings(items, now: now, gap: gap)
            .map { sitting in
                let offered = Array(distinctShots(sitting).prefix(photoLimit))
                let ids = Set(offered.map(\.id))
                return PhotoSuggestionCluster(items: offered, others: sitting.filter { ids.contains($0.id) == false })
            }
            .sorted { $0.date > $1.date }
    }

    /// A sitting less its retakes, oldest first: a photo within ``sameShot`` of the last one kept is
    /// the same shot again. Measured from the kept photo, so a long burst is still one shot.
    static func distinctShots(_ sitting: [PhotoSuggestionItem]) -> [PhotoSuggestionItem] {
        var kept: [PhotoSuggestionItem] = []
        for item in sitting {
            if let last = kept.last, item.createdAt.timeIntervalSince(last.createdAt) < sameShot { continue }
            kept.append(item)
        }
        return kept
    }

    /// The sittings whole, oldest photo first in each — before the composer's five are taken.
    static func sittings(
        _ items: [PhotoSuggestionItem],
        now: Date,
        gap: TimeInterval = PhotoSuggestions.gap
    ) -> [[PhotoSuggestionItem]] {
        let recent = items
            .filter { now.timeIntervalSince($0.createdAt) <= window && $0.createdAt <= now }
            .sorted { $0.createdAt < $1.createdAt }
        var clusters: [[PhotoSuggestionItem]] = []
        for item in recent {
            if let last = clusters.last?.last, item.createdAt.timeIntervalSince(last.createdAt) <= gap {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }
        return clusters
    }

    /// How a sitting is named. Inside the last week it is the day and the part of it; exactly a week
    /// back, "Last Sunday"; older than that, the date — the artboard's own three rows.
    public static func title(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        var calendar = calendar
        calendar.locale = locale
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        switch days {
        case 0: return partOfDay(for: date, calendar: calendar).capitalizedFirst
        case 1: return "Yesterday \(partOfDay(for: date, calendar: calendar))"
        case 2...6: return "\(weekday) \(partOfDay(for: date, calendar: calendar))"
        case 7: return "Last \(weekday)"
        default:
            return date.formatted(Date.VerbatimFormatStyle(
                format: "\(day: .defaultDigits) \(month: .wide)",
                locale: locale, timeZone: calendar.timeZone, calendar: calendar
            ))
        }
    }

    /// "9:40 pm" — the clock the artboard prints, in the reader's own locale. The formatter parts
    /// the minutes from the meridiem with a narrow no-break space; the artboard uses a plain one.
    public static func time(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.hour().minute()
        return date.formatted(style)
            .lowercased()
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func partOfDay(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case ..<11: "morning"
        case ..<15: "lunch"
        case ..<17: "afternoon"
        default: "night"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
