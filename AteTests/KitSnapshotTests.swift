import SnapshotTesting
import SwiftUI
import XCTest
@testable import Ate

/// **The kit's visual contract.** Each page of the component gallery (`KitGalleryScreen`) is drawn at
/// phone width in light and dark and compared with the approved picture in `__Snapshots__`. A frost
/// band, a tint, a line height or a contrast change fails here, before a TestFlight build. Motion is
/// not covered: nothing automated sees a frame in flight.
///
/// Drawn with `ImageRenderer`, not a hosting controller: a page is far taller than the screen, and a
/// hosting view that tall drew only its last screenful (the first recording, 25 Oct). The renderer
/// lays the page out at its own height and knows nothing about windows. Two of its quirks are
/// accepted, since the pictures are compared with each other, not with the phone: a page over about
/// 8,000 px comes back blank (so the composites are two pages), and a few 8 pt bands between
/// sections are left transparent, which viewers show as black.
///
/// Re-record on purpose only: push a commit whose message contains `[record-snapshots]` and
/// `.github/workflows/snapshots.yml` commits the new pictures back to the branch. The diff of the
/// pictures is then part of the PR, for the reviewer to judge against `design/v1`.
///
/// Reduce Motion is on in the simulator that draws these (both workflows set it with `simctl spawn
/// defaults write`; the environment key is read-only): the one-shot score shimmer, the page loader's
/// tally and the posting dots are all clocks, and every one of them goes still under it. Without it
/// the same page recorded and compared minutes apart on the same runner disagreed.
@MainActor
final class KitSnapshotTests: XCTestCase {
    func testAtoms() { snapshot(.atoms) }
    func testComposites() { snapshot(.composites) }
    func testPaper() { snapshot(.paper) }
    func testLists() { snapshot(.lists) }
    func testShare() { snapshot(.share) }
    func testChrome() { snapshot(.chrome) }

    /// iPhone 17 Pro's point width; 2x keeps the pictures legible in a diff without a 3x file size.
    private static let width: CGFloat = 393
    private static let scale: CGFloat = 2

    private func snapshot(
        _ section: KitGalleryScreen.Section,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let page = KitGalleryScreen(only: section)
                .frame(width: Self.width)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: page)
            renderer.scale = Self.scale
            renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
            guard let image = renderer.uiImage else {
                XCTFail("\(section) (\(name)) did not render", file: file, line: line)
                continue
            }
            if image.size.height * Self.scale > 8_000 {
                let px = Int(image.size.height * Self.scale)
                XCTFail("\(section) (\(name)) is \(px) px tall; ImageRenderer goes blank near 8,192 px. "
                        + "Split the page in KitGalleryScreen.Section.", file: file, line: line)
                continue
            }
            let picture = Self.reference(file: file, testName: testName, name: name)
            if let place = Self.whereItDiffers(image, from: picture) {
                XCTFail("\(section) (\(name)) differs from its picture: \(place)", file: file, line: line)
            }
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98, scale: Self.scale),
                named: name, file: file, testName: testName, line: line
            )
        }
    }

    // MARK: - Where a picture differs

    /// The approved picture `assertSnapshot` will compare with.
    private static func reference(file: StaticString, testName: String, name: String) -> URL {
        let test = testName.replacingOccurrences(of: "()", with: "")
        return URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/KitSnapshotTests/\(test).\(name).png")
    }

    /// Which rows of the page changed, in pixels, so a failure in CI says where to look without the
    /// result bundle: `assertSnapshot` only says that the picture does not match. Nil when there is no
    /// picture yet (recording) or nothing differs.
    private static func whereItDiffers(_ image: UIImage, from reference: URL) -> String? {
        guard let old = UIImage(contentsOfFile: reference.path) else { return nil }
        guard let new = pixels(image), let was = pixels(old) else { return "could not read the pixels" }
        guard new.width == was.width, new.height == was.height else {
            return "size \(new.width)x\(new.height) px, picture \(was.width)x\(was.height) px"
        }
        var rows: [Int] = []
        var total = 0
        for row in 0..<new.height {
            var count = 0
            let start = row * new.width * 4
            for col in 0..<new.width {
                let at = start + col * 4
                if abs(Int(new.bytes[at]) - Int(was.bytes[at])) > 8
                    || abs(Int(new.bytes[at + 1]) - Int(was.bytes[at + 1])) > 8
                    || abs(Int(new.bytes[at + 2]) - Int(was.bytes[at + 2])) > 8 {
                    count += 1
                }
            }
            if count > 0 { rows.append(row); total += count }
        }
        guard total > 0 else { return nil }
        var bands: [(from: Int, to: Int)] = []
        for row in rows {
            if let last = bands.last, row - last.to <= 24 {
                bands[bands.count - 1].to = row
            } else {
                bands.append((row, row))
            }
        }
        let share = Double(total) / Double(new.width * new.height) * 100
        let list = bands.prefix(12).map { "\($0.from)-\($0.to)" }.joined(separator: ", ")
        return String(format: "%.2f%% of pixels, in %d band(s) of rows: %@%@",
                      share, bands.count, list, bands.count > 12 ? ", …" : "")
    }

    private static func pixels(_ image: UIImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, bytes)
    }
}
