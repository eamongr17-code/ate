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

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    @Test("at home the photo is exactly the tile: its square, corners and tilt, not the photo's shape")
    func homeIsTheTile() {
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: -3, image: portrait)
        #expect(home.rect == tile)
        #expect(home.size.width == home.size.height)
        #expect(home.radius == 14)
        #expect(home.angle == -3)
    }

    @Test("at home the picture is cropped as the tile's fill crops it: full width, its middle")
    func homeCropsLikeAFill() {
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: 0, image: portrait)
        // 3024 wide fills 80: the picture is 80 × 106.67, centred, so 13.33 hangs off top and bottom.
        #expect(close(home.picture, CGRect(x: 0, y: -40.0 / 3, width: 80, height: 320.0 / 3)))
        let landscape = PhotoFlight.home(tile: tile, radius: 14, angle: 0, image: CGSize(width: 400, height: 200))
        #expect(close(landscape.picture, CGRect(x: -40, y: 0, width: 160, height: 80)))
    }

    @Test("a dish page's focus crop lands the picture where the tile's focused crop draws it")
    func homeKeepsTheFocus() {
        // The right half's top quarter of a 400×400 picture fills the tile.
        let crop = CGRect(x: 200, y: 0, width: 200, height: 200)
        let square = CGSize(width: 400, height: 400)
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: 0, image: square, crop: crop)
        #expect(close(home.picture, CGRect(x: -80, y: 0, width: 160, height: 160)))
    }

    @Test("at rest it is the whole photo, fitted to the page and centred, square-cornered, uncropped")
    func awayIsTheWholePhoto() throws {
        let away = try #require(PhotoFlight.away(image: portrait, page: page, anchor: anchor))
        #expect(abs(away.size.width - 402) < 0.001)
        #expect(abs(away.size.height - 536) < 0.001)
        #expect(away.center == CGPoint(x: 201, y: 437))
        #expect(away.radius == 0)
        #expect(away.angle == 0)
        #expect(away.picture == CGRect(origin: .zero, size: away.size))
    }

    @Test("halfway it is between the two; at 0 and 1 it is each end exactly, so nothing snaps")
    func middleIsBetween() throws {
        let home = PhotoFlight.home(tile: tile, radius: 14, angle: -3, image: portrait)
        let away = try #require(PhotoFlight.away(image: portrait, page: page, anchor: anchor))
        let middle = PhotoFlight.between(home, away, progress: 0.5)
        #expect(abs(middle.size.width - 241) < 0.001)
        #expect(abs(middle.size.height - 308) < 0.001)
        #expect(middle.radius == 7)
        #expect(middle.angle == -1.5)
        #expect(middle.center == CGPoint(x: 140.5, y: 388.5))
        #expect(close(middle.picture, CGRect(x: 0, y: -20.0 / 3, width: 241, height: 268 + 160.0 / 3)))
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
