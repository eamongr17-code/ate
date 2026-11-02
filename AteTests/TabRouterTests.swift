import XCTest
@testable import Ate

/// **The Journal tab comes back on the Journal** (feedback #7, 2 Nov): a re-tap of the tab, or the
/// tab left while a list is open, asks the root for its first shelf; a list's page is closed on the
/// way out, and any other page stays where it was.
@MainActor
final class TabRouterTests: XCTestCase {
    private func router(_ path: [Route] = []) -> TabRouter<Void> {
        TabRouter(tab: .journal, path: path) {}
    }

    private let list = Route.list(ListRoute(id: UUID()))
    private let entry = Route.entry(EntryRoute(entryID: UUID()))

    func testReTapAtTheRootAsksForTheFirstShelfAndScrollsUp() {
        let router = router()
        router.reselected()
        XCTAssertEqual(router.firstShelfShown, 1)
        XCTAssertEqual(router.scrollToTop, 1)
    }

    func testReTapOnAListPagePopsHomeToTheFirstShelf() {
        let router = router([list])
        router.reselected()
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.firstShelfShown, 1)
    }

    func testLeavingFromAListPageClosesItAndResetsTheShelf() {
        let router = router([list, entry])
        router.left()
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.firstShelfShown, 1)
    }

    func testLeavingFromAnotherPageKeepsIt() {
        let router = router([entry])
        router.left()
        XCTAssertEqual(router.path, [entry])
        XCTAssertEqual(router.firstShelfShown, 1)
    }
}
