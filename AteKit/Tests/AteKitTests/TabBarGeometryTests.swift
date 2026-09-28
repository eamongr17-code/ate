import CoreGraphics
import Testing
@testable import AteKit

/// Round 6's bug — "when the bottom nav shrinks down, the icons on the left side are incorrectly
/// aligned" — as geometry: minimised, the current tab's icon sits dead centre in its disc, and on
/// the way there it travels straight, never jumping.
struct TabBarGeometryTests {
    /// iOS 26's bar on a 402pt phone: 21 in either side.
    private let bar = TabBarGeometry(width: 402 - 42, tabCount: 4)

    @Test func theFullBarMatchesBuild80() {
        #expect(bar.capsule(isExpanded: true) == CGRect(x: 0, y: 0, width: 290, height: 62))
        #expect(bar.plus(isExpanded: true) == CGRect(x: 298, y: 0, width: 62, height: 62))
        #expect(abs(bar.slot - 68.667) < 0.01)
        // Build 80's icons were centred at 62.8, 131.7, 200.7 and 269 on screen (21 in).
        let expected: [CGFloat] = [62.8, 131.7, 200.7, 269.0]
        for (index, screenX) in expected.enumerated() {
            #expect(abs(bar.slotCentre(index).x + 21 - screenX) < 0.6)
        }
    }

    @Test func theMinimisedBarMatchesBuild80() {
        // A 48 disc at 28…76 on screen, and a 48 + on the full size's centre.
        #expect(bar.capsule(isExpanded: false) == CGRect(x: 7, y: 7, width: 48, height: 48))
        #expect(bar.plus(isExpanded: false) == CGRect(x: 305, y: 7, width: 48, height: 48))
        #expect(bar.plus(isExpanded: false).midX == bar.plus(isExpanded: true).midX)
    }

    @Test func minimisedTheIconIsDeadCentreInItsDisc() {
        let icon = TabBarGeometry.iconCentre(faceCentre: bar.minimisedFace)
        let disc = bar.capsule(isExpanded: false)
        #expect(icon.x == disc.midX)
        #expect(icon.y == disc.midY)
    }

    @Test func centringTheFaceOnTheDiscIsTheBug() {
        // What build 81 did: the face on the disc's centre put the icon 7 above it.
        let icon = TabBarGeometry.iconCentre(faceCentre: bar.discCentre)
        #expect(bar.discCentre.y - icon.y == 7)
    }

    @Test func fullTheIconsSitWhereBuild80DrewThem() {
        for index in 0..<4 {
            let icon = TabBarGeometry.iconCentre(faceCentre: bar.expandedFace(index))
            #expect(icon.x == bar.slotCentre(index).x)
            #expect(icon.y == 24, "12 down, a 24 box: the icon's centre is 24 from the bar's top")
        }
    }

    @Test func theMorphMovesEachIconInAStraightLine() {
        // Faces are animated by position; the icon's offset inside a face is constant, so an icon's
        // path is the face's path shifted — a straight line from its slot to the disc's centre.
        let start = TabBarGeometry.iconCentre(faceCentre: bar.expandedFace(0))
        let end = TabBarGeometry.iconCentre(faceCentre: bar.minimisedFace)
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            let fraction = CGFloat(step)
            let face = CGPoint(
                x: bar.expandedFace(0).x + (bar.minimisedFace.x - bar.expandedFace(0).x) * fraction,
                y: bar.expandedFace(0).y + (bar.minimisedFace.y - bar.expandedFace(0).y) * fraction
            )
            let icon = TabBarGeometry.iconCentre(faceCentre: face)
            #expect(abs(icon.x - (start.x + (end.x - start.x) * fraction)) < 0.0001)
            #expect(abs(icon.y - (start.y + (end.y - start.y) * fraction)) < 0.0001)
        }
    }

    @Test func thePillStaysInsideTheCapsule() {
        #expect(abs(bar.pillMinX(0) - 4) < 0.0001)
        #expect(abs(bar.pillMinX(3) + TabBarGeometry.pillWidth - (bar.capsuleWidth - 4)) < 0.0001)
        #expect(abs(bar.pillMinX(1) - (bar.slotCentre(1).x - 38)) < 0.0001)
    }
}
