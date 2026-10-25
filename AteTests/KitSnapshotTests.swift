import SnapshotTesting
import SwiftUI
import XCTest
@testable import Ate

/// **The kit's visual contract.** Each page of the component gallery (`KitGalleryScreen`) is drawn at
/// phone width in light and dark and compared with the approved picture in `__Snapshots__`. A frost
/// band, a tint, a line height or a contrast change fails here, before a TestFlight build. Motion is
/// not covered: nothing automated sees a frame in flight.
///
/// Drawn in a real window, after the page has settled. `ImageRenderer` drew whatever state the
/// first pass had: the photo cluster's ring, a sticker's text fit, a notification row and the
/// skeleton's breath all depend on measured frames, tasks and clocks, and the same page came out
/// differently light and dark, run after run. Here the page is hosted in an offscreen window as tall
/// as itself (the screen-sized hosting view of the first recording drew only its last screenful),
/// the run loop turns for a moment, and the layer tree is drawn. Materials draw flat this way, which
/// is fine: the pictures are compared with each other, not with the phone.
///
/// Re-record on purpose only: push a commit whose message contains `[record-snapshots]` and
/// `.github/workflows/snapshots.yml` commits the new pictures back to the branch. The diff of the
/// pictures is then part of the PR, for the reviewer to judge against `design/v1`.
///
/// Reduce Motion is on in the simulator that draws these (both workflows write the preference and
/// reboot the simulator; the environment key is read-only): the printing receipt's breath, the page
/// loader's tally and the posting dots are all clocks, and every one of them goes still under it.
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
            guard let image = Self.draw(page, scheme: scheme) else {
                XCTFail("\(section) (\(name)) did not render", file: file, line: line)
                continue
            }
            if image.size.height * Self.scale > 12_000 {
                let px = Int(image.size.height * Self.scale)
                XCTFail("\(section) (\(name)) is \(px) px tall; split the page in KitGalleryScreen.Section.",
                        file: file, line: line)
                continue
            }
            if Self.isBlank(image) {
                XCTFail("\(section) (\(name)) drew a single colour; the window did not render", file: file, line: line)
                continue
            }
            let picture = Self.reference(file: file, testName: testName, name: name)
            if let place = Self.whereItDiffers(image, from: picture) {
                XCTFail("\(section) (\(name)) differs from its picture: \(place)", file: file, line: line)
                Self.printThumbnail(of: image, as: "\(section).\(name)")
            }
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98, scale: Self.scale),
                named: name, file: file, testName: testName, line: line
            )
        }
    }

    // MARK: - Drawing a page

    /// How long the page gets to settle: measured frames, `.task`s (the page loader waits 0.4 s) and
    /// the one-shot shimmer (0.9 s) are all done well within it.
    private static let settle: TimeInterval = 1.5

    private static func draw(_ page: some View, scheme: ColorScheme) -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }
        let hosting = UIHostingController(rootView: page)
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        let tall = CGSize(width: width, height: .greatestFiniteMagnitude)
        var height = hosting.sizeThatFits(in: tall).height.rounded(.up)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        turn(settle)
        let settled = hosting.sizeThatFits(in: tall).height.rounded(.up)
        if settled != height {
            height = settled
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.layoutIfNeeded()
            turn(0.5)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    /// Lets the main run loop turn, so SwiftUI commits its state and layout.
    private static func turn(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
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

    /// The new picture at quarter size, as JPEG base64 in 4,000-character lines tagged `SNAPSHOT_B64`,
    /// so a reader with only the CI log can see what was drawn (the result bundle is a download CI's
    /// reader cannot fetch). Reassemble: join the lines of one name in order, base64-decode.
    private static func printThumbnail(of image: UIImage, as name: String) {
        let size = CGSize(width: image.size.width / 2, height: image.size.height / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = small.jpegData(compressionQuality: 0.5) else { return }
        let text = data.base64EncodedString()
        let step = 4_000
        let parts = stride(from: 0, to: text.count, by: step).map { start -> Substring in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: min(step, text.count - start))
            return text[from..<to]
        }
        for (index, part) in parts.enumerated() {
            print("SNAPSHOT_B64 \(name) \(index + 1)/\(parts.count) \(part)")
        }
    }

    private static func isBlank(_ image: UIImage) -> Bool {
        guard let drawn = pixels(image), let first = drawn.bytes.first else { return true }
        return drawn.bytes.allSatisfy { $0 == first }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static func pixels(_ image: UIImage) -> Pixels? {
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
        return Pixels(width: width, height: height, bytes: bytes)
    }
}
