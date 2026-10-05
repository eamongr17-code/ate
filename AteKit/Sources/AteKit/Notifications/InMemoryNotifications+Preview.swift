#if DEBUG
import Foundation

public extension InMemoryNotifications {
    /// The mockup's own list (`design/rebuild/ate-with.html`, section 2), told from the preview
    /// viewer's side: Jess ate with you at Tipo 00 on Saturday, Marcus at Supernormal on Thursday.
    static func preview(viewer: EntryCard.Author, latency: Duration = .milliseconds(450)) -> InMemoryNotifications {
        InMemoryNotifications(
            tags: [PreviewTags.tipo, PreviewTags.supernormal], viewer: viewer, firstOrderNumber: 144, latency: latency
        )
    }
}

enum PreviewTags {
    static let jess = AteNotification.Person(
        id: UUID(uuidString: "11111111-0000-4000-8000-000000000003")!, username: "jessw", name: "Jess W"
    )
    static let marcus = AteNotification.Person(
        id: UUID(uuidString: "11111111-0000-4000-8000-000000000004")!, username: "marcus.eats", name: "Marcus"
    )

    static let tipo: InMemoryNotifications.Tag = {
        let place = AteWithPrefill.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!, name: "Tipo 00",
            address: "361 Little Bourke St", locality: "Melbourne"
        )
        // Saturday 19 September 2026, 7.30pm in Melbourne.
        let visited = Date(timeIntervalSince1970: 1_789_810_200)
        return tag(
            notification: "A7E0C000-0000-4000-8000-000000000001", companion: "A7E0C000-0000-4000-8000-0000000000C1",
            entry: "A7E0C000-0000-4000-8000-0000000000E1", by: jess, place: place, visited: visited,
            dishes: [
                ("D7E00000-0000-4000-8000-000000000001", "Tagliatelle al ragù"),
                ("D7E00000-0000-4000-8000-000000000002", "Tiramisu"),
                ("D7E00000-0000-4000-8000-000000000003", "Prawn spaghetti")
            ]
        )
    }()

    static let supernormal: InMemoryNotifications.Tag = {
        let place = AteWithPrefill.Place(
            id: UUID(uuidString: "B7E00000-0000-4000-8000-0000000000A1")!, name: "Supernormal",
            address: "180 Flinders Ln", locality: "Melbourne"
        )
        // Thursday 17 September 2026, 7pm in Melbourne.
        let visited = Date(timeIntervalSince1970: 1_789_635_600)
        return tag(
            notification: "A7E0C000-0000-4000-8000-000000000002", companion: "A7E0C000-0000-4000-8000-0000000000C2",
            entry: "A7E0C000-0000-4000-8000-0000000000E2", by: marcus, place: place, visited: visited,
            dishes: [
                ("D7E00000-0000-4000-8000-0000000000A1", "New England lobster roll"),
                ("D7E00000-0000-4000-8000-0000000000A2", "Peanut butter parfait")
            ]
        )
    }()

    // swiftlint:disable:next function_parameter_count
    private static func tag(
        notification: String, companion: String, entry: String, by tagger: AteNotification.Person,
        place: AteWithPrefill.Place, visited: Date, dishes: [(String, String)]
    ) -> InMemoryNotifications.Tag {
        let companionID = UUID(uuidString: companion)!
        let entryID = UUID(uuidString: entry)!
        return InMemoryNotifications.Tag(
            notification: AteNotification(
                id: UUID(uuidString: notification)!, createdAt: visited.addingTimeInterval(3 * 3_600), actor: tagger,
                companionID: companionID, entryID: entryID,
                place: AteNotification.Place(id: place.id, name: place.name, locality: place.locality),
                visitedAt: visited
            ),
            prefill: AteWithPrefill(
                companionID: companionID, entryID: entryID, visitedAt: visited, tagger: tagger, place: place,
                dishes: dishes.enumerated().map { index, dish in
                    AteWithPrefill.Dish(dishID: UUID(uuidString: dish.0)!, dishName: dish.1, position: index + 1)
                }
            )
        )
    }
}
#endif
