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
        let lines: [Line] = [
            Line("Beach Mezze", 3, 12, "3.0", 0, "Beach Mezze"),
            Line("Chicken Satay Skewers", 3.5, 125, "3.5", 103, "Chicken satay skewers"),
            Line(
                "Linguine Frutti di Mare", 2, 131, "Linguine Frutti di Mare 2.0", 131, "Linguine Frutti di Mare"
            ),
            Line("Tiger Prawns", 4, 204, "Tiger Prawns 4.0", 204, "Tiger Prawns")
        ]
        return EntryCard(
            id: UUID(), authorID: UUID(), body: body, orderNumber: 1, sortStatus: .sorted,
            sortedAt: Date(timeIntervalSince1970: 1_793_000_000),
            createdAt: Date(timeIntervalSince1970: 1_792_990_000),
            updatedAt: Date(timeIntervalSince1970: 1_793_600_000),
            place: EntryCard.Place(id: UUID(), name: "The Lazy Coconut"),
            items: lines.enumerated().map { index, line in
                EntryCard.Item(
                    reviewID: UUID(), dishID: UUID(), dishName: line.dish, score: Rating(exactly: line.score),
                    position: index + 1,
                    evidenceOffset: line.evidenceAt, evidenceLength: line.evidence.unicodeScalars.count,
                    mentionOffset: line.mentionAt, mentionLength: line.mention.unicodeScalars.count
                )
            }
        )
    }

    /// An empty draw is never cached, so one bad render can't leave a score's pill blank all session.
    func testAnEmptyPillIsNotKept() throws {
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in }
        XCTAssertFalse(TokenPill.hasInk(clear))
        let pill = try XCTUnwrap(TokenPill.image(
            for: .score(try XCTUnwrap(Rating(exactly: 2))), prose: 17, palette: .automatic,
            dynamicTypeSize: .large, scale: 2
        ))
        XCTAssertTrue(TokenPill.hasInk(pill))
    }

    /// Only the empty line between two notes shrinks; the lines of words keep their height.
    func testOnlyTheBlankLineShrinks() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        paragraph.lineSpacing = 4
        let string = NSMutableAttributedString(string: "One\n\nTwo", attributes: [.paragraphStyle: paragraph])
        InlineTokenLabel.tightenBlankLines(in: string)
        let blank = try XCTUnwrap(string.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(blank.maximumLineHeight, 28 * InlineTokenLabel.blankLineShare, accuracy: 0.01)
        XCTAssertEqual(blank.lineSpacing, 0)
        let words = try XCTUnwrap(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(words.maximumLineHeight, 24)
        let next = try XCTUnwrap(string.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(next.maximumLineHeight, 24)
    }

    func testLazyCoconutWords() {
        let composition = EntryPresentation.composition(for: Self.card())
        let spans = composition.spans.map { ($0.span.location, $0.token.plainText) }
        print("merged words spans:", spans)
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

/// One receipt line as prod holds it: dish, score, and where its evidence and mention sit.
private struct Line {
    let dish: String
    let score: Double
    let evidenceAt: Int
    let evidence: String
    let mentionAt: Int
    let mention: String
    init(_ dish: String, _ score: Double, _ evidenceAt: Int, _ evidence: String, _ mentionAt: Int, _ mention: String) {
        (self.dish, self.score, self.evidenceAt) = (dish, score, evidenceAt)
        (self.evidence, self.mentionAt, self.mention) = (evidence, mentionAt, mention)
    }
}
