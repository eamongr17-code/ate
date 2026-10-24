import CoreGraphics
import Testing
@testable import AteKit

@Suite("A photo flies between its tile and the screen, cropped to the tile all the way")
struct PhotoFlightTests {
    /// A portrait photo on a slip's 80pt tile, opened on a 402×874 phone.
    let tile = CGRect(x: 40, y: 300, width: 80, height: 80)
    let portrait = CGSize(width: 3024, height: 4032)
    let page = CGRect(x: 0, y: 0, width: 402, height: 874)
    var anchor: CGPoint { CGPoint(x: page.midX, y: page.midY) }

    @Test("at home the photo is exactly the tile: its square, corners and tilt, not the photo's shape")
    func homeIsTheTile() {
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: -3)
        #expect(home.rect == tile)
        #expect(home.size.width == home.size.height)
        #expect(home.radius == 14)
        #expect(home.angle == -3)
    }

    @Test("at rest it is the whole photo, fitted to the page and centred, square-cornered")
    func awayIsTheWholePhoto() throws {
        let away = try #require(PhotoFlight.away(image: portrait, page: page, anchor: anchor))
        #expect(abs(away.size.width - 402) < 0.001)
        #expect(abs(away.size.height - 536) < 0.001)
        #expect(away.center == CGPoint(x: 201, y: 437))
        #expect(away.radius == 0)
        #expect(away.angle == 0)
    }

    @Test("halfway it is between the two: neither the tile's square nor the photo's shape")
    func middleIsBetween() throws {
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: -3)
        let away = try #require(PhotoFlight.away(image: portrait, page: page, anchor: anchor))
        let middle = PhotoFlight.between(home, away, progress: 0.5)
        #expect(abs(middle.size.width - 241) < 0.001)
        #expect(abs(middle.size.height - 308) < 0.001)
        #expect(middle.radius == 7)
        #expect(middle.angle == -1.5)
        #expect(middle.center == CGPoint(x: 140.5, y: 388.5))
        #expect(PhotoFlight.between(home, away, progress: 0) == home)
        #expect(PhotoFlight.between(home, away, progress: 1) == away)
    }

    @Test("dragged down, it follows the finger and shrinks as the pager does")
    func dragShrinks() throws {
        let away = try #require(PhotoFlight.away(image: portrait, page: page, anchor: anchor, drag: 200))
        #expect(abs(away.size.width - 402 * 0.9) < 0.001)
        #expect(away.center == CGPoint(x: 201, y: 637))
        #expect(PhotoFlight.scale(drag: 2000) == 0.8)
    }

    @Test("a page inset from the screen centres the photo on the page, not the screen")
    func insetPage() throws {
        let inset = CGRect(x: 0, y: 62, width: 402, height: 778)
        let away = try #require(PhotoFlight.away(image: portrait, page: inset, anchor: anchor))
        #expect(away.center.y == inset.midY)
    }

    @Test("no photo shape, no flight; a tile off the screen fades instead")
    func refusals() {
        #expect(PhotoFlight.away(image: .zero, page: page, anchor: anchor) == nil)
        #expect(PhotoFlight.canLand(on: tile, screen: page.size))
        #expect(PhotoFlight.canLand(on: tile.offsetBy(dx: 0, dy: 820), screen: page.size) == false)
    }
}
