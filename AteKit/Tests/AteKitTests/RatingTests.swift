import Foundation
import Testing

@testable import AteKit

@Suite("Rating")
struct RatingTests {
    @Test("exact construction accepts only what the server's CHECK accepts", arguments: [
        (0.5, true), (1.0, true), (2.5, true), (5.0, true),
        (0.0, false), (0.25, false), (4.3, false), (5.5, false), (-1.0, false)
    ])
    func exactConstruction(value: Double, isValid: Bool) {
        #expect((Rating(exactly: value) != nil) == isValid)
    }

    @Test("a drag snaps to the nearest half-step and clamps into 0.5...5.0", arguments: [
        (0.0, 0.5), (-3.0, 0.5), (0.24, 0.5), (0.26, 0.5), (1.24, 1.0), (1.26, 1.5),
        (4.99, 5.0), (7.0, 5.0)
    ])
    func snapping(input: Double, expected: Double) {
        #expect(Rating(rounding: input).value == expected)
    }

    @Test("there is no zero rating — an unrated dish is a nil DishStats.score, not a 0 Rating")
    func noZeroRating() {
        #expect(Rating(exactly: 0) == nil)
        #expect(Rating.minimum.value == 0.5)
        #expect(Rating(rounding: 0).value == 0.5)
    }

    @Test("star rendering splits into whole and half stars", arguments: [
        (0.5, 0, true), (1.0, 1, false), (3.5, 3, true), (5.0, 5, false)
    ])
    func starRendering(value: Double, filled: Int, half: Bool) throws {
        let rating = try #require(Rating(exactly: value))
        #expect(rating.filledStars == filled)
        #expect(rating.hasHalfStar == half)
    }

    @Test("ratings compare and round-trip through JSON as a bare number")
    func codableRoundTrip() throws {
        #expect(Rating.minimum < Rating.maximum)

        let encoded = try JSONEncoder().encode(Rating(rounding: 3.5))
        #expect(String(bytes: encoded, encoding: .utf8) == "3.5")
        #expect(try JSONDecoder().decode(Rating.self, from: encoded).value == 3.5)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Rating.self, from: Data("0".utf8))
        }
    }
}
