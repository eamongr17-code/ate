import Foundation
import Testing

@testable import AteKit

@Suite("Photo tilt — each slip leans its own way")
struct PhotoTiltTests {
    private let ids = (0..<400).map { _ in UUID() }

    @Test("the same entry always gets the same angles")
    func stable() throws {
        let id = try #require(UUID(uuidString: "6F1C2A4E-9B3D-4E21-8C7A-2D5F0B8E9A13"))
        #expect(PhotoTilt.angles(seed: id, count: 3) == PhotoTilt.angles(seed: id, count: 3))
        // A longer cluster starts the same way: adding a photo doesn't re-tilt the first.
        #expect(Array(PhotoTilt.angles(seed: id, count: 5).prefix(3)) == PhotoTilt.angles(seed: id, count: 3))
    }

    @Test("never near straight, never past six degrees")
    func range() {
        for id in ids {
            for angle in PhotoTilt.angles(seed: id, count: 5) {
                #expect(abs(angle) >= PhotoTilt.minimum && abs(angle) <= PhotoTilt.maximum)
            }
        }
    }

    @Test("neighbours lean opposite ways")
    func alternates() {
        for id in ids {
            let angles = PhotoTilt.angles(seed: id, count: 4)
            for (a, b) in zip(angles, angles.dropFirst()) { #expect((a > 0) != (b > 0)) }
        }
    }

    @Test("single photos vary across entries, on both sides")
    func varies() {
        let singles = ids.compactMap { PhotoTilt.angles(seed: $0, count: 1).first }
        #expect(Set(singles).count >= 12)
        #expect(singles.contains { $0 > 0 } && singles.contains { $0 < 0 })
    }

    @Test("no photos, no angles")
    func empty() {
        #expect(PhotoTilt.angles(seed: UUID(), count: 0).isEmpty)
    }
}
