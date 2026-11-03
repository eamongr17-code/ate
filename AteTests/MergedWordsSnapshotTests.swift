import AteKit
import SwiftUI
import XCTest
@testable import Ate

/// **The words of an entry folded from three posts the same day** (0104), as prod holds them for
/// Eamon's Lazy Coconut lunch on 27 Oct: three notes joined by a blank line, four lines whose score
/// offsets point into the joined words. On his phone the 2.0 pill drew as an empty gap; this draws
/// the same words, through the same composition and label the slip uses, so the picture shows what
/// the code does with them.
@MainActor
final class MergedWordsSnapshotTests: XCTestCase {
    static let body = "Beach Mezze 3.0, everything was fresh and tasty, but I was hoping for more (better) "
        + "pita bread tbh V \n\nChicken satay skewers 3.5 \n\nLinguine Frutti di Mare 2.0 tasted a bit like "
        + "wiggles pasta tbh, but the Tiger Prawns 4.0 were so fresh and delicious "

    static func card() -> EntryCard {
        // (dish, score, evidence offset, evidence text, mention offset, mention text), as prod has them.
        let lines: [(String, Double, Int, String, Int, String)] = [
            ("Beach Mezze", 3, 12, "3.0", 0, "Beach Mezze"),
            ("Chicken Satay Skewers", 3.5, 125, "3.5", 103, "Chicken satay skewers"),
            ("Linguine Frutti di Mare", 2, 131, "Linguine Frutti di Mare 2.0", 131, "Linguine Frutti di Mare"),
            ("Tiger Prawns", 4, 204, "Tiger Prawns 4.0", 204, "Tiger Prawns")
        ]
        return EntryCard(
            id: UUID(), authorID: UUID(), body: body, orderNumber: 1, sortStatus: .sorted,
            sortedAt: Date(timeIntervalSince1970: 1_793_000_000),
            createdAt: Date(timeIntervalSince1970: 1_792_990_000),
            updatedAt: Date(timeIntervalSince1970: 1_793_600_000),
            place: EntryCard.Place(id: UUID(), name: "The Lazy Coconut"),
            items: lines.enumerated().map { index, line in
                EntryCard.Item(
                    reviewID: UUID(), dishID: UUID(), dishName: line.0, score: Rating(exactly: line.1),
                    position: index + 1,
                    evidenceOffset: line.2, evidenceLength: line.3.unicodeScalars.count,
                    mentionOffset: line.4, mentionLength: line.5.unicodeScalars.count
                )
            }
        )
    }

    func testLazyCoconutWords() {
        let composition = EntryPresentation.composition(for: Self.card())
        print("merged words spans:", composition.spans.map { ($0.span.location, $0.span.length, $0.token.plainText) })
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let page = InlineTokenText(composition: composition, style: .slipProse)
                .padding(16)
                .frame(width: 393)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
            let shot = SnapshotPicture.Shot(
                label: "merged words", name: name, scheme: scheme, frame: .tall(width: 393), settle: 1.5
            )
            SnapshotPicture.check(page, shot, file: #filePath, testName: #function, line: #line)
        }
    }
}
