import AteKit
import SwiftUI
import XCTest
@testable import Ate

/// **The main screens' visual contract.** Journal, Feed, Saved and You, a place and an entry, each
/// drawn as the phone draws it — the real tab shell, its header and its bar — on the preview data
/// (`-ate-preview-data`), in light and dark, and compared with the approved picture in
/// `__Snapshots__`. Where `KitSnapshotTests` catches a component that changed, this catches a screen
/// that composes them wrong: a missing row, a header over the content, a section in the wrong order.
///
/// The scheme's test action launches the host with `-ate-preview-data -ate-ui-testing`, so every
/// read here is the in-memory fixtures (never staging) and first-run tips stay down. Each picture
/// gets its own services, so nothing one screen does is on the next one's page.
///
/// Drawn and judged by `SnapshotPicture`, at the simulator's own screen size. Re-record on purpose
/// only, with a `[record-snapshots]` commit, exactly as for the kit (see `KitSnapshotTests`): a change
/// to one of these screens is expected to fail here until its pictures are re-recorded and judged.
///
/// Nothing on these pages may depend on when the test runs. The clock is pinned (`RelativeAge.pin`)
/// to the evening after the design's own visit, so the feed's "2h", a visit's day and the journal's
/// "this year" are the same in every run; and the preview data's ids are seeded, never `UUID()`,
/// because tiles, avatars and photo tilts take their look from the id.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    func testJournal() { snapshot(.journal) }
    func testFeed() { snapshot(.feed) }
    func testSaved() { snapshot(.saved) }
    func testYou() { snapshot(.you) }
    /// Tipo 00, opened from the Journal: The Top Ate, and the visits with yours first.
    func testPlace() {
        snapshot(.journal, opening: .place(Self.tipo))
    }
    /// Your own visit, opened from its Journal slip.
    func testEntry() {
        snapshot(.journal, opening: .entry(EntryCard.previewSorted))
    }
    /// Somebody else's visit (Jess's, 2h ago), opened from the Feed: the byline and the bookmarks.
    func testEntryFromFeed() throws {
        // The seed's dates are read from the pinned clock, so it is pinned before the card is taken.
        RelativeAge.pin(Self.pinnedNow)
        let jess = try XCTUnwrap(InMemorySocialService.seededEntries.first { $0.id == Self.jessAtTipo })
        snapshot(.feed, opening: .entry(jess))
    }

    /// Sun 20 Sep 2026, 8:14 pm in Melbourne: a day after the design's Tipo 00 visit.
    private static let pinnedNow = Date(timeIntervalSince1970: 1_789_899_240)

    private static let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
    private static let jessAtTipo = UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!

    /// Longer than the kit's: a tab reads its stores on appearing, the photos load through the image
    /// pipeline, and the bell's count arrives after the notifications' 0.45 s.
    private static let settle: TimeInterval = 3

    private func snapshot(
        _ tab: V2Tab, opening route: Route? = nil,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        guard DebugLaunch.isOn(.previewData), DebugLaunch.isOn(.uiTesting) else {
            XCTFail("The Ate scheme's test action must launch with -ate-preview-data -ate-ui-testing",
                    file: file, line: line)
            return
        }
        guard let environment = try? AteEnvironment.resolve(bundle: .main) else {
            XCTFail("The test host has no environment (Config/Secrets.xcconfig)", file: file, line: line)
            return
        }
        RelativeAge.pin(Self.pinnedNow)
        defer { RelativeAge.pin(nil) }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let app = AppModel(services: AteServices(environment: environment))
            let start = V2Launch.Start(tab: tab, path: route.map { [$0] } ?? [])
            let screen = TabShell(app: app, start: start)
                .environment(app.gate)
                .environment(\.colorScheme, scheme)
            SnapshotPicture.check(
                screen, label: "\(tab)\(route == nil ? "" : " + page")", named: name, scheme: scheme,
                frame: .screen, settle: Self.settle, file: file, testName: testName, line: line
            )
        }
    }
}
