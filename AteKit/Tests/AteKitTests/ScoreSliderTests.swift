import Foundation
import Testing
@testable import AteKit

@Suite("Score slider")
struct ScoreSliderTests {
    private let pill = UUID()
    private let other = UUID()

    private func opened(_ rating: Rating? = .minimum) -> ScoreSlider {
        var slider = ScoreSlider()
        slider.open(tokenID: pill, dishName: "the ragù", rating: rating)
        return slider
    }

    @Test("Opening shows the pill's own value, not settling")
    func opens() {
        let slider = opened(Rating(rounding: 3))
        #expect(slider.isOpen)
        #expect(slider.session?.id == pill)
        #expect(slider.session?.rating == Rating(rounding: 3))
        #expect(slider.session?.isSettling == false)
    }

    @Test("A slide reports a change once per value, so the pill is rewritten once per half-step")
    func slideReportsChanges() {
        var slider = opened()
        let outcome1 = slider.slide(to: Rating(rounding: 2))
        #expect(outcome1)
        let outcome2 = slider.slide(to: Rating(rounding: 2))
        #expect(outcome2 == false)
        let outcome3 = slider.slide(to: Rating(rounding: 2.5))
        #expect(outcome3)
        #expect(slider.session?.rating == Rating(rounding: 2.5))
    }

    @Test("A slide with no panel open changes nothing")
    func slideWhenClosed() {
        var slider = ScoreSlider()
        let outcome4 = slider.slide(to: .maximum)
        #expect(outcome4 == false)
        #expect(slider.isOpen == false)
    }

    @Test("Lifting keeps the panel up until its settle, then closes it")
    func finishThenSettle() throws {
        var slider = opened()
        let issued = slider.finish(at: Rating(rounding: 4.5))
        let ticket = try #require(issued)
        #expect(slider.isOpen)
        #expect(slider.session?.isSettling == true)
        #expect(slider.session?.rating == Rating(rounding: 4.5))
        let outcome5 = slider.settle(ticket)
        #expect(outcome5)
        #expect(slider.isOpen == false)
    }

    @Test("Touching the panel again while it settles keeps it up")
    func slideCancelsSettle() throws {
        var slider = opened()
        let issued = slider.finish(at: Rating(rounding: 4))
        let ticket = try #require(issued)
        slider.slide(to: Rating(rounding: 3.5))
        let outcome6 = slider.settle(ticket)
        #expect(outcome6 == false)
        #expect(slider.isOpen)
        #expect(slider.session?.isSettling == false)
    }

    @Test("A stale settle never closes a panel reopened on another pill")
    func staleSettleAfterReopen() throws {
        var slider = opened()
        let issued = slider.finish(at: Rating(rounding: 4))
        let ticket = try #require(issued)
        slider.open(tokenID: other, dishName: "the tiramisu", rating: .minimum)
        let outcome7 = slider.settle(ticket)
        #expect(outcome7 == false)
        #expect(slider.session?.id == other)
    }

    @Test("Only the latest of two finishes may close the panel")
    func onlyLatestFinishSettles() throws {
        var slider = opened()
        let firstTicket = slider.finish(at: Rating(rounding: 2))
        let first = try #require(firstTicket)
        let secondTicket = slider.finish(at: Rating(rounding: 5))
        let second = try #require(secondTicket)
        let outcome8 = slider.settle(first)
        #expect(outcome8 == false)
        #expect(slider.isOpen)
        let outcome9 = slider.settle(second)
        #expect(outcome9)
        #expect(slider.isOpen == false)
    }

    @Test("Dismiss always closes: open, sliding, or settling")
    func dismissFromAnyState() throws {
        var open = opened()
        open.dismiss()
        #expect(open.isOpen == false)

        var sliding = opened()
        sliding.slide(to: .maximum)
        sliding.dismiss()
        #expect(sliding.isOpen == false)

        var settling = opened()
        let issued = settling.finish(at: .maximum)
        let ticket = try #require(issued)
        settling.dismiss()
        #expect(settling.isOpen == false)
        // …and the settle that was on its way does nothing to a closed panel.
        let outcome10 = settling.settle(ticket)
        #expect(outcome10 == false)
    }

    @Test("A settle after a dismiss and a fresh open leaves the fresh panel up")
    func settleAfterDismissAndReopen() throws {
        var slider = opened()
        let issued = slider.finish(at: .maximum)
        let ticket = try #require(issued)
        slider.dismiss()
        slider.open(tokenID: pill, dishName: "the ragù", rating: .maximum)
        let outcome11 = slider.settle(ticket)
        #expect(outcome11 == false)
        #expect(slider.isOpen)
    }

    @Test("Finishing with no panel open hands back no ticket")
    func finishWhenClosed() {
        var slider = ScoreSlider()
        let outcome12 = slider.finish(at: .maximum)
        #expect(outcome12 == nil)
    }

    @Test("The panel closes when its pill leaves the words, and only then")
    func pillDeleted() {
        var slider = opened()
        let outcome13 = slider.retain(onlyIfPresentIn: [pill, other])
        #expect(outcome13 == false)
        #expect(slider.isOpen)
        let outcome14 = slider.retain(onlyIfPresentIn: [other])
        #expect(outcome14)
        #expect(slider.isOpen == false)
    }

    @Test("The settle delay is half a second")
    func delay() {
        #expect(ScoreSlider.settleDelay == .milliseconds(500))
    }
}
