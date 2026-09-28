import Foundation
import Testing
@testable import AteKit

/// A sorted entry by somebody, some minutes ago, with one scored dish — the browse suites' row.
enum BrowseFixtures {
    static func card(
        _ minutesAgo: Double,
        id: UUID = UUID(),
        isMine: Bool = false,
        photos: [String] = [],
        city: String? = "Melbourne"
    ) -> EntryCard {
        let author = isMine ? ViewerProfile.preview.id : UUID()
        return EntryCard(
            id: id,
            authorID: author,
            body: "Tipo 00 was good.",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
            isMine: isMine,
            author: EntryCard.Author(id: author, username: "jessw"),
            place: EntryCard.Place(id: UUID(), name: "Tipo 00", city: city),
            photos: photos.enumerated().map { EntryCard.Photo(url: $1, position: $0) },
            items: [EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Prawn spaghetti",
                                   score: Rating(rounding: 5), position: 1)]
        )
    }
}
