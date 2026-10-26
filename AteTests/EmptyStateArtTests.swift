import UIKit
import XCTest
@testable import Ate

/// **Every empty-state drawing ships.** Each ``AteEmptyArt`` case is drawn from two template layers,
/// `Empty<rawValue>Ink` and `Empty<rawValue>Paper`, rendered from `design/illustrations/kit.js`. A
/// missing or misnamed imageset draws nothing at all, with no error, so the kit snapshots only catch it
/// for the few kinds the gallery shows. This checks all of them.
final class EmptyStateArtTests: XCTestCase {
    func testEveryKindHasBothLayers() {
        for art in AteEmptyArt.allCases {
            for layer in ["Ink", "Paper"] {
                let name = "Empty\(art.rawValue)\(layer)"
                let image = UIImage(named: name)
                XCTAssertNotNil(image, "\(name) is missing from Assets.xcassets/EmptyStates")
                XCTAssertEqual(image?.renderingMode, .alwaysTemplate, "\(name) must be a template image")
            }
        }
    }
}
