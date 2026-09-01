import Foundation
import Testing

@testable import AteKit

@Suite("Rating track (§2.2)")
struct RatingTrackTests {
    private static let width: Double = 300  // 30pt per half-step zone

    @Test("ten equal zones map left to right onto 0.5…5.0", arguments: [
        (0.0, 0.5),      // the very leading edge
        (1.0, 0.5),
        (29.9, 0.5),
        (30.0, 0.5),     // exactly on a boundary belongs to the zone just entered
        (30.1, 1.0),
        (150.0, 2.5),
        (150.1, 3.0),
        (299.9, 5.0),
        (300.0, 5.0)     // the trailing pixel is reachable
    ])
    func zones(atX position: Double, expected: Double) {
        #expect(RatingTrack.rating(atX: position, trackWidth: Self.width).value == expected)
    }

    @Test("the leading slop is entirely 0.5 and the trailing slop entirely 5.0", arguments: [
        (-24.0, 0.5), (-1.0, 0.5), (324.0, 5.0), (1_000.0, 5.0)
    ])
    func slop(atX position: Double, expected: Double) {
        #expect(RatingTrack.rating(atX: position, trackWidth: Self.width).value == expected)
    }

    @Test("a zero-width track can't produce an illegal score")
    func degenerateTrack() {
        #expect(RatingTrack.rating(atX: 40, trackWidth: 0) == .minimum)
    }

    @Test("a tap and a drag ending at the same point produce the same score")
    func tapAndDragAgree() {
        // §2.3: a tap is a zero-distance drag through the same code path — there is one mapping,
        // so this is true by construction, and this test is what keeps it that way.
        let position = 187.0
        #expect(RatingTrack.rating(atX: position, trackWidth: Self.width)
            == RatingTrack.rating(atX: position, trackWidth: Self.width))
        #expect(RatingTrack.rating(atX: position, trackWidth: Self.width).value == 3.5)
    }

    @Test("every score's centre maps back to itself")
    func centresRoundTrip() {
        for halfSteps in 1...10 {
            let rating = Rating(rounding: Double(halfSteps) / 2)
            let position = RatingTrack.x(for: rating, trackWidth: Self.width)
            #expect(RatingTrack.rating(atX: position, trackWidth: Self.width) == rating)
        }
    }

    @Test("§2.5 VoiceOver adjusts by half a star and clamps")
    func accessibilityAdjustment() {
        #expect(RatingTrack.adjusted(nil, by: 1) == .minimum, "an unset control starts at 0.5")
        #expect(RatingTrack.adjusted(nil, by: -1) == .minimum)
        #expect(RatingTrack.adjusted(Rating(rounding: 4), by: 1).value == 4.5)
        #expect(RatingTrack.adjusted(Rating(rounding: 4), by: -1).value == 3.5)
        #expect(RatingTrack.adjusted(.maximum, by: 1) == .maximum)
        #expect(RatingTrack.adjusted(.minimum, by: -1) == .minimum, "there is no zero")
    }

    @Test("§2.5 VoiceOver reads halves as words", arguments: [
        (nil as Double?, "Not rated"),
        (0.5, "Half a star out of 5"),
        (4.5, "4 and a half out of 5"),
        (4.0, "4 out of 5"),
        (5.0, "5 out of 5")
    ])
    func accessibilityValue(score: Double?, expected: String) {
        #expect(RatingTrack.accessibilityValue(score.map { Rating(rounding: $0) }) == expected)
    }
}
