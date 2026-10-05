#if DEBUG
import Foundation

public extension InMemoryLists {
    /// **The preview shelf**: three lists — "Melbourne's best burgers" with six dishes, a short pasta
    /// list off the design's own Tipo 00 visit, and one with nothing on it yet. The picker searches the
    /// burgers, the preview journal's lines, and a few unscored ones.
    static func preview(journal: [EntryCard] = [.previewSorted, .previewCroissant], now: Date = .now)
        -> InMemoryLists {
        let journalLines = lines(from: journal)
        let lists = InMemoryLists(lines: burgers(now: now) + journalLines + extras(now: now))
        let day: TimeInterval = 24 * 60 * 60
        lists.seed(name: "Date night", lines: [], createdAt: now.addingTimeInterval(-1 * day))
        lists.seed(
            name: "Pasta worth the trip",
            lines: journalLines.filter { $0.score != nil }.prefix(2).map(\.line),
            createdAt: now.addingTimeInterval(-6 * day)
        )
        lists.seed(
            name: "Melbourne\u{2019}s best burgers",
            lines: burgers(now: now).map(\.line),
            createdAt: now.addingTimeInterval(-9 * day)
        )
        return lists
    }

    /// Every dish line on these entries, as the picker would answer them.
    static func lines(from cards: [EntryCard]) -> [ListPickerDish] {
        var seen = Set<DishLine>()
        return cards.flatMap { card in
            card.items.compactMap { item -> ListPickerDish? in
                guard seen.insert(DishLine(entryID: card.id, dishID: item.dishID)).inserted else { return nil }
                return ListPickerDish(
                    entryID: card.id, dishID: item.dishID, dishName: item.dishName, restaurantID: card.place?.id,
                    restaurantName: card.place?.name, locality: card.place?.locality, score: item.score,
                    photoURL: card.photos.first?.url, visitedAt: card.createdAt
                )
            }
        }
    }

    private static func burgers(now: Date) -> [ListPickerDish] {
        let rows: [PreviewLine] = [
            PreviewLine("Double cheeseburger", "Royal Stacks", "Collingwood", 6, 12),
            PreviewLine("Smash burger", "Rockwell & Sons", "Collingwood", 5, 20),
            PreviewLine("Bacon cheeseburger", "Andrew\u{2019}s Hamburgers", "Albert Park", 4.5, 31),
            PreviewLine("Fried chicken burger", "Belles Hot Chicken", "Fitzroy", 4.5, 44),
            PreviewLine("The Classic", "Easey\u{2019}s", "Collingwood", 4, 58),
            PreviewLine("Mushroom burger", "Huxtaburger", "Fitzroy", nil, 73)
        ]
        return rows.enumerated().map { offset, row in
            ListPickerDish(
                entryID: fixedID("B0E00000", offset), dishID: fixedID("B0D00000", offset), dishName: row.dish,
                restaurantID: fixedID("B0F00000", offset), restaurantName: row.place, locality: row.locality,
                score: row.score.flatMap { Rating(exactly: $0) },
                visitedAt: now.addingTimeInterval(-Double(row.daysAgo) * 24 * 60 * 60)
            )
        }
    }

    private static func extras(now: Date) -> [ListPickerDish] {
        let rows: [PreviewLine] = [
            PreviewLine("Pork xiao long bao", "HuTong Dumpling Bar", "CBD", 4.5, 5),
            PreviewLine("Lobster roll", "Supernormal", "CBD", nil, 15),
            PreviewLine("Margherita", "Leonardo\u{2019}s Pizza Palace", "Carlton", 3.5, 26)
        ]
        return rows.enumerated().map { offset, row in
            ListPickerDish(
                entryID: fixedID("B0E10000", offset), dishID: fixedID("B0D10000", offset), dishName: row.dish,
                restaurantID: fixedID("B0F10000", offset), restaurantName: row.place, locality: row.locality,
                score: row.score.flatMap { Rating(exactly: $0) },
                visitedAt: now.addingTimeInterval(-Double(row.daysAgo) * 24 * 60 * 60)
            )
        }
    }

    private struct PreviewLine {
        let dish: String
        let place: String
        let locality: String
        let score: Double?
        let daysAgo: Int

        init(_ dish: String, _ place: String, _ locality: String, _ score: Double?, _ daysAgo: Int) {
            self.dish = dish
            self.place = place
            self.locality = locality
            self.score = score
            self.daysAgo = daysAgo
        }
    }

    private static func fixedID(_ prefix: String, _ offset: Int) -> UUID {
        UUID(uuidString: "\(prefix)-0000-4000-8000-\(String(format: "%012d", offset + 1))")!
    }
}
#endif
