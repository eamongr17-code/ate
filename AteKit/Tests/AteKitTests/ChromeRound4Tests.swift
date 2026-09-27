import Foundation
import Testing
@testable import AteKit

/// Round 4's chrome logic: the tab root header that comes back on the way up, and the bottom sheet
/// that fits what it holds.
struct ChromeRound4Tests {

    // MARK: - The floating header

    private func scroll(_ track: inout AteHeaderTrack, through offsets: [CGFloat], max: CGFloat = 2000,
                        byPerson: Bool = true) {
        for offset in offsets {
            track.update(.init(offset: offset, maxOffset: max), isPersonScrolling: byPerson)
        }
    }

    @Test func atRestTheHeaderInThePageIsTheOne() {
        let track = AteHeaderTrack()
        #expect(track.isFloating == false)
    }

    @Test func scrollingDownNeverRaisesIt() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 10, 40, 120, 400])
        #expect(track.isFloating == false)
    }

    @Test func aScrollUpMidListRaisesItStraightAway() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 100, 300, 600, 590, 580])
        #expect(track.isFloating)
    }

    @Test func aJitterUnderTheHysteresisChangesNothing() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 100, 300, 600, 597, 599, 596])
        #expect(track.isFloating == false)
    }

    @Test func scrollingDownAgainLowersIt() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 300, 600, 580, 560])
        #expect(track.isFloating)
        scroll(&track, through: [570, 590])
        #expect(track.isFloating == false)
    }

    @Test func reachingTheTopHandsBackToThePage() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 300, 600, 400, 200, 50])
        #expect(track.isFloating)
        scroll(&track, through: [0.5])
        #expect(track.isFloating == false)
        scroll(&track, through: [-40]) // pulled to refresh
        #expect(track.isFloating == false)
    }

    /// The bounce at the bottom of the list swings back up; it is not the reader scrolling up.
    @Test func theBounceAtTheBottomIsNotAScrollUp() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 400, 800, 852, 884, 870, 852], max: 852)
        #expect(track.isFloating == false)
    }

    /// Content the system moves (a programmatic scroll, the bar resizing) is not a direction either.
    @Test func onlyAPersonsScrollCounts() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 300, 600])
        scroll(&track, through: [500, 400], byPerson: false)
        #expect(track.isFloating == false)
    }

    /// The bar's shadow follows the app's model of the bar: gone on the way down, back on the way
    /// up and at the top.
    @Test func theBarIsExpandedAtTheTopAndOnTheWayUpOnly() {
        var track = AteHeaderTrack()
        #expect(track.isBarExpanded)
        scroll(&track, through: [0, 100, 300])
        #expect(track.isBarExpanded == false)
        scroll(&track, through: [290, 280])
        #expect(track.isBarExpanded)
        scroll(&track, through: [290, 300])
        #expect(track.isBarExpanded == false)
        scroll(&track, through: [0])
        #expect(track.isBarExpanded)
    }

    // MARK: - The fitted sheet

    @Test func aSheetWithAPillFitsHeadContentAndPill() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.hasFoot = true
        fit.head = 90
        fit.body = 240
        #expect(fit.tallest == 0, "not until the pill is measured too")
        fit.foot = 88
        #expect(fit.tallest == CGFloat(90 + 240 + 88 + 28))
    }

    @Test func aSheetWithoutAPillKeepsTheDesignsClearance() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 240
        #expect(fit.tallest == CGFloat(50 + 240 + 34 + 14))
    }

    @Test func itGrowsWithItsContentAndNeverShrinksUnderTheThumb() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 100
        fit.body = 400
        let grown = fit.tallest
        fit.body = 60 // results thinning out as you type
        #expect(fit.tallest == grown)
    }

    @Test func nothingIsFittedBeforeTheFirstLayout() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.body = 300
        #expect(fit.tallest == 0)
    }
}
