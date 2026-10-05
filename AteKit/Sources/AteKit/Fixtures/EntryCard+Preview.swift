#if DEBUG
import Foundation

public extension EntryCard {
    /// The design's own entry, sorted — the fixture every preview and the in-memory service start
    /// from, so what a screenshot shows and what `design/v1` draws are the same words. Written the
    /// way the composer writes now: the place is on the entry, not in the words (ComposerPlaceB).
    static let previewSorted = previewTipo(tagged: false)

    /// …and the same visit with its dietary tags (`DietTagsB`): "Tiramisu v", "prawn spaghetti gf".
    static let previewSortedTagged = previewTipo(tagged: true)

    private static func previewTipo(tagged: Bool) -> EntryCard {
        let body = tagged
            ? "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in "
                + "four minutes. Tiramisu v 3.0 a bit flat after that. Jess's prawn spaghetti gf looked the "
                + "business."
            : "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in "
                + "four minutes. Tiramisu 3.0 a bit flat after that. Jess's prawn spaghetti looked the "
                + "business."
        // Offsets in Unicode scalars, found rather than hand-counted — the unit the server serves.
        func offset(of needle: String) -> Int? {
            body.range(of: needle).map { body.unicodeScalars.distance(from: body.startIndex, to: $0.lowerBound) }
        }
        return EntryCard(
            id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!,
            authorID: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
            body: body,
            restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
            restaurantSource: "user",
            orderNumber: 142,
            sortStatus: .sorted,
            // Sat 19 Sep 2026, 8:14 pm in Melbourne — the artboard's day.
            sortedAt: Date(timeIntervalSince1970: 1_789_812_940),
            createdAt: Date(timeIntervalSince1970: 1_789_812_840),
            author: Author(id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
                           username: "eamon", city: "Melbourne"),
            place: Place(id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
                         name: "Tipo 00", address: "361 Little Bourke St", city: "Melbourne",
                         locality: "CBD"),
            // The artboard's own three photos, bundled as prototype assets.
            photos: [
                Photo(url: "asset://ragu", position: 1),
                Photo(url: "asset://prawn", position: 2),
                Photo(url: "asset://tiramisu", position: 3)
            ],
            items: [
                // The offsets are the real ones for this body, so a preview, a screenshot and a UI
                // drive all render through the offset path the server feeds (`-ate-preview-data`'s
                // locally sorted entries carry none, and exercise the fallback — both halves of
                // ``EntryBodyTokens`` are reachable on a simulator).
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000001")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000001")!,
                     dishName: "Tagliatelle al ragù", score: Rating(rounding: 4.5),
                     note: "Unreal. Rich, glossy, gone in four minutes.", position: 1,
                     evidenceOffset: offset(of: "4.5"), evidenceLength: 3,
                     mentionOffset: offset(of: "tagliatelle al ragù"), mentionLength: 19),
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000002")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000002")!,
                     dishName: "Tiramisu", score: Rating(rounding: 3),
                     note: "A bit flat after that.", position: 2,
                     evidenceOffset: offset(of: "3.0"), evidenceLength: 3,
                     mentionOffset: offset(of: "Tiramisu"), mentionLength: 8,
                     tags: tagged ? [.v] : []),
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000003")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000003")!,
                     dishName: "Prawn spaghetti", position: 3,
                     mentionOffset: offset(of: "prawn spaghetti"), mentionLength: 15,
                     tags: tagged ? [.gf] : [])
            ],
            // "With Jess for her birthday": Jess, tagged and posted her own entry for the visit
            // (`ate-with.html` 1f) — the seeded feed's Tipo 00 slip is hers.
            companions: [
                EntryCompanion(userID: InMemorySocialService.Seed.jess, username: "jessw", name: "Jess W",
                               status: .accepted,
                               entryID: UUID(uuidString: "E0000000-0000-4000-8000-000000000001"))
            ]
        )
    }

    /// `Main.dc.html`'s second slip: one dish, one photo, Thu 17 Sep.
    static let previewCroissant: EntryCard = {
        let body = "Queued twenty minutes like everyone else and the almond croissant 5.0 is the best "
            + "thing I have eaten this year."
        // Offsets in Unicode scalars, found rather than hand-counted.
        func offset(of needle: String) -> Int? {
            body.range(of: needle).map { body.unicodeScalars.distance(from: body.startIndex, to: $0.lowerBound) }
        }
        return EntryCard(
            id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000141")!,
            authorID: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
            body: body,
            restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000009")!,
            restaurantSource: "user",
            orderNumber: 141,
            sortStatus: .sorted,
            // Thu 17 Sep 2026, 9:40 am in Melbourne.
            sortedAt: Date(timeIntervalSince1970: 1_789_602_100),
            createdAt: Date(timeIntervalSince1970: 1_789_602_000),
            author: Author(id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
                           username: "eamon", city: "Melbourne"),
            place: Place(id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000009")!,
                         name: "Lune Croissanterie", address: "119 Rose St", city: "Melbourne",
                         locality: "CBD"),
            photos: [Photo(url: "asset://cake", position: 1)],
            items: [
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000141")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000141")!,
                     dishName: "Almond croissant", score: Rating(rounding: 5),
                     note: "The best thing I have eaten this year.", position: 1,
                     evidenceOffset: offset(of: "5.0"), evidenceLength: 3,
                     mentionOffset: offset(of: "almond croissant"), mentionLength: 16)
            ]
        )
    }()
}
#endif
