import Foundation
import Testing
@testable import AteKit

/// Places and entries on given UTC days — the journal suites' rows.
enum JournalFixtures {
    static let tipo = EntryCard.Place(id: UUID(), name: "Tipo 00", locality: "CBD")

    static let lune = EntryCard.Place(id: UUID(), name: "Lune", locality: "Fitzroy")

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// An entry on a given UTC day, at a place, with dishes scored as given (`nil` = unscored).
    static func card(
        _ year: Int, _ month: Int, _ day: Int,
        at place: EntryCard.Place? = tipo,
        scores: [Double?] = [4],
        tags: [DietTag] = []
    ) -> EntryCard {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return EntryCard(
            id: UUID(),
            authorID: ViewerProfile.preview.id,
            body: "Words",
            restaurantID: place?.id,
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: date,
            place: place,
            items: scores.enumerated().map { index, score in
                EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Dish \(index)",
                               score: score.map { Rating(rounding: $0) }, position: index + 1, tags: tags)
            }
        )
    }
}
