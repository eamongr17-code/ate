import Foundation
import Testing
@testable import AteKit

/// Round 5's chrome: the app's own tab bar, minimised on the way down, can be tapped back open —
/// and the next scroll down minimises it again rather than finding nothing changed.
struct ChromeRound5Tests {

    private func scroll(_ track: inout AteHeaderTrack, through offsets: [CGFloat], max: CGFloat = 2000) {
        for offset in offsets {
            track.update(.init(offset: offset, maxOffset: max), isPersonScrolling: true)
        }
    }

    @Test func aTapOnTheMinimisedBarExpandsIt() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 100, 300])
        #expect(track.isBarExpanded == false)
        track.expandBar()
        #expect(track.isBarExpanded)
        #expect(track.isFloating == false, "tapping the bar open does not bring the header back")
    }

    @Test func theNextScrollDownAfterATapMinimisesItAgain() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 100, 300])
        track.expandBar()
        scroll(&track, through: [310, 330])
        #expect(track.isBarExpanded == false)
    }

    @Test func aTapClearsTheTravelSoAJitterDoesNotMinimise() {
        var track = AteHeaderTrack()
        scroll(&track, through: [0, 100, 300, 303])
        track.expandBar()
        scroll(&track, through: [305])
        #expect(track.isBarExpanded, "a couple of points is under the hysteresis")
    }
}
