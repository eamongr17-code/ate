import SwiftUI
import XCTest
@testable import Ate

/// **The kit's visual contract.** Each page of the component gallery (`KitGalleryScreen`) is drawn at
/// phone width in light and dark and compared with the approved picture in `__Snapshots__`. A frost
/// band, a tint, a line height or a contrast change fails here, before a TestFlight build. Motion is
/// not covered: nothing automated sees a frame in flight.
///
/// Drawn and judged by `SnapshotPicture`: a settled offscreen window, as tall as the page, and the
/// harness's own pixel comparison.
///
/// Re-record on purpose only: push a commit whose message contains `[record-snapshots]` and
/// `.github/workflows/snapshots.yml` commits the new pictures back to the branch. The diff of the
/// pictures is then part of the PR, for the reviewer to judge against `design/v1`. CI tests the PR
/// merged into its base while the recording draws the branch as pushed, so merge the base in first:
/// a kit change that landed on the base since the branch was cut shows up here as a mismatch.
///
/// Reduce Motion is on in the simulator that draws these (both workflows write the preference and
/// reboot the simulator; the environment key is read-only): the printing receipt's breath, the page
/// loader's tally and the posting dots are all clocks, and every one of them goes still under it.
@MainActor
final class KitSnapshotTests: XCTestCase {
    func testAtoms() { snapshot(.atoms) }
    func testComposites() { snapshot(.composites) }
    func testPaper() { snapshot(.paper) }
    func testLists() { snapshot(.lists) }
    func testShare() { snapshot(.share) }
    func testChrome() { snapshot(.chrome) }

    /// iPhone 17 Pro's point width.
    private static let width: CGFloat = 393

    /// How long the page gets to settle: measured frames, `.task`s (the page loader waits 0.4 s) and
    /// the one-shot shimmer (0.9 s) are all done well within it.
    private static let settle: TimeInterval = 1.5

    private func snapshot(
        _ section: KitGalleryScreen.Section,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let page = KitGalleryScreen(only: section)
                .frame(width: Self.width)
                .environment(\.colorScheme, scheme)
            let shot = SnapshotPicture.Shot(
                label: "\(section)", name: name, scheme: scheme, frame: .tall(width: Self.width), settle: Self.settle
            )
            SnapshotPicture.check(page, shot, file: file, testName: testName, line: line)
        }
    }
}
