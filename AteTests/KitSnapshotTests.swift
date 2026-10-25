import SnapshotTesting
import SwiftUI
import XCTest
@testable import Ate

/// **The kit's visual contract.** Each page of the component gallery (`KitGalleryScreen`) is drawn at
/// phone width in light and dark and compared with the approved picture in `__Snapshots__`. A frost
/// band, a tint, a line height or a contrast change fails here, before a TestFlight build. Motion is
/// not covered: nothing automated sees a frame in flight.
///
/// Drawn with `ImageRenderer`, not a hosting controller: a page is far taller than the screen, and a
/// hosting view that tall drew only its last screenful (the first recording, 25 Oct). The renderer
/// lays the page out at its own height and knows nothing about windows. Two of its quirks are
/// accepted, since the pictures are compared with each other, not with the phone: a page over about
/// 8,000 px comes back blank (so the composites are two pages), and a few 8 pt bands between
/// sections are left transparent, which viewers show as black.
///
/// Re-record on purpose only: push a commit whose message contains `[record-snapshots]` and
/// `.github/workflows/snapshots.yml` commits the new pictures back to the branch. The diff of the
/// pictures is then part of the PR, for the reviewer to judge against `design/v1`.
@MainActor
final class KitSnapshotTests: XCTestCase {
    func testAtoms() { snapshot(.atoms) }
    func testComposites() { snapshot(.composites) }
    func testPaper() { snapshot(.paper) }
    func testLists() { snapshot(.lists) }
    func testShare() { snapshot(.share) }
    func testChrome() { snapshot(.chrome) }

    /// iPhone 17 Pro's point width; 2x keeps the pictures legible in a diff without a 3x file size.
    private static let width: CGFloat = 393
    private static let scale: CGFloat = 2

    private func snapshot(
        _ section: KitGalleryScreen.Section,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let page = KitGalleryScreen(only: section)
                .frame(width: Self.width)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: page)
            renderer.scale = Self.scale
            renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
            guard let image = renderer.uiImage else {
                XCTFail("\(section) (\(name)) did not render", file: file, line: line)
                continue
            }
            if image.size.height * Self.scale > 8_000 {
                let px = Int(image.size.height * Self.scale)
                XCTFail("\(section) (\(name)) is \(px) px tall; ImageRenderer goes blank near 8,192 px. "
                        + "Split the page in KitGalleryScreen.Section.", file: file, line: line)
                continue
            }
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98, scale: Self.scale),
                named: name, file: file, testName: testName, line: line
            )
        }
    }
}
