import Foundation
import Testing

@testable import AteKit

@Suite("Score formatting — the unrated state")
struct ScoreFormatTests {
    @Test("an unrated aggregate reads as –/5, never 0")
    func unratedIsNeverZero() {
        #expect(ScoreFormat.outOfFive(nil) == "–/5")
        #expect(ScoreFormat.average(nil) == "–")
        // The regression this whole type exists to prevent.
        #expect(ScoreFormat.outOfFive(nil).contains("0") == false)
    }

    @Test("a rated aggregate keeps one decimal, and drops a trailing .0")
    func ratedFormatting() {
        #expect(ScoreFormat.outOfFive(4.3) == "4.3/5")
        #expect(ScoreFormat.outOfFive(5) == "5/5")
        #expect(ScoreFormat.average(3.76) == "3.8")
    }

    @Test("a half-step rating always shows one decimal, so a live readout never changes width")
    func halfStepFormatting() {
        #expect(ScoreFormat.halfStep(4) == "4.0")
        #expect(ScoreFormat.halfStep(4.5) == "4.5")
        #expect(ScoreFormat.halfStep(0.5) == "0.5")
        #expect(ScoreFormat.halfStep(nil) == "–")
    }

    /// The rule the design language names out loud: `average` is for aggregates, `halfStep` is for
    /// one person's score. Both renderings of 3.0 are correct — for different things — which is
    /// exactly why the wrong one is easy to reach for and hard to spot in a diff.
    @Test("a whole-number score reads differently as an aggregate and as one review")
    func scoreFormatRoleSeparation() {
        #expect(ScoreFormat.average(3.0) == "3")
        #expect(ScoreFormat.halfStep(3.0) == "3.0")
        #expect(ScoreFormat.average(5.0) == "5")
        #expect(ScoreFormat.halfStep(5.0) == "5.0")
        // A single review can only ever be a half-step, so this is the whole domain.
        for halfSteps in 1...10 {
            let value = Double(halfSteps) / 2
            let rendered = ScoreFormat.halfStep(value)
            #expect(rendered.contains("."), "a review score must keep its decimal: \(rendered)")
        }
    }

    @Test("review count copy invites the first review instead of saying zero")
    func reviewCountCopy() {
        #expect(ScoreFormat.reviewCount(0) == "No reviews yet")
        #expect(ScoreFormat.reviewCount(1) == "1 review")
        #expect(ScoreFormat.reviewCount(12) == "12 reviews")
    }

    @Test("stars round an average to the nearest half")
    func starRounding() {
        #expect(ScoreFormat.stars(for: nil).full == 0)
        #expect(ScoreFormat.stars(for: nil).half == false)
        let fourAndAHalf = ScoreFormat.stars(for: 4.3)
        #expect(fourAndAHalf.full == 4 && fourAndAHalf.half)
        let four = ScoreFormat.stars(for: 4.1)
        #expect(four.full == 4 && four.half == false)
        let five = ScoreFormat.stars(for: 4.8)
        #expect(five.full == 5 && five.half == false)
        // Clamped: no sixth star from bad data.
        #expect(ScoreFormat.stars(for: 7).full == 5)
    }
}
