import SnapshotTesting
import SwiftUI
import XCTest

/// **How both snapshot suites take a picture and judge it** — the kit's gallery pages
/// (`KitSnapshotTests`) and the app's main screens (`ScreenSnapshotTests`) are drawn the same way and
/// held to the same tolerance, so a failure means the same thing in both.
///
/// Drawn in a real window, after the page has settled. `ImageRenderer` drew whatever state the
/// first pass had: the photo cluster's ring, a sticker's text fit, a notification row and the
/// skeleton's breath all depend on measured frames, tasks and clocks, and the same page came out
/// differently light and dark, run after run. Here the page is hosted in an offscreen window (as
/// tall as itself for a gallery page, the phone's own screen for a screen), the run loop turns for a
/// moment, and the layer tree is drawn. Materials draw flat this way, which is fine: the pictures
/// are compared with each other, not with the phone.
///
/// The verdict is this file's own pixel comparison (`whereItDiffers`), which names the rows that
/// changed; SnapshotTesting only writes the pictures when recording.
@MainActor
enum SnapshotPicture {
    /// 2x keeps the pictures legible in a diff without a 3x file size.
    static let scale: CGFloat = 2

    /// What a picture is drawn into.
    enum Frame {
        /// A gallery page: this wide, as tall as the page itself, no safe area.
        case tall(width: CGFloat)
        /// A screen: the simulator's own screen, with its status bar and home indicator insets.
        case screen

        /// The rows at the bottom the comparison leaves out, in points. The tab bar is the system's
        /// Liquid Glass, whose edge highlight is drawn differently from one run to the next (1.8% of a
        /// screen between two recordings of the same entry page): it is drawn in the picture, for the
        /// reviewer, but never judged. Its icons and labels are the kit's `chrome` page's business.
        var unjudgedBottom: CGFloat {
            switch self {
            case .tall: 0
            case .screen: 100
            }
        }
    }

    /// `snapshots.yml` sets `TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all`, which reaches the test host
    /// without the prefix; SnapshotTesting then writes every picture instead of comparing.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"] != nil
    }

    /// One picture of a page: how a failure names it, which picture it is ("light", "dark"), and how
    /// it is drawn.
    struct Shot {
        let label: String
        let name: String
        let scheme: ColorScheme
        let frame: Frame
        /// How long the page gets to settle before it is drawn.
        let settle: TimeInterval
    }

    /// Draws `page` and holds it to its approved picture, `__Snapshots__/<suite>/<test>.<name>.png`.
    static func check(_ page: some View, _ shot: Shot, file: StaticString, testName: String, line: UInt) {
        let label = shot.label
        let name = shot.name
        let frame = shot.frame
        guard let image = draw(page, scheme: shot.scheme, frame: frame, settle: shot.settle) else {
            XCTFail("\(label) (\(name)) did not render", file: file, line: line)
            return
        }
        if image.size.height * scale > 12_000 {
            let px = Int(image.size.height * scale)
            XCTFail("\(label) (\(name)) is \(px) px tall; split the page in KitGalleryScreen.Section.",
                    file: file, line: line)
            return
        }
        if isBlank(image) {
            XCTFail("\(label) (\(name)) drew a single colour; the window did not render", file: file, line: line)
            return
        }
        if isRecording {
            assertSnapshot(
                of: image, as: .image(scale: scale),
                named: name, file: file, testName: testName, line: line
            )
            return
        }
        let picture = reference(file: file, testName: testName, name: name)
        guard FileManager.default.fileExists(atPath: picture.path) else {
            XCTFail("\(label) (\(name)) has no picture yet; push a [record-snapshots] commit",
                    file: file, line: line)
            return
        }
        let skipped = Int(frame.unjudgedBottom * scale)
        guard let difference = whereItDiffers(image, from: picture, skippingBottom: skipped) else { return }
        if difference.isBeyondTolerance {
            XCTFail("\(label) (\(name)) differs from its picture: \(difference.where)", file: file, line: line)
            printThumbnail(of: image, as: "\(label).\(name)")
        } else {
            print("snapshot \(label) (\(name)) within tolerance: \(difference.where)")
        }
    }

    // MARK: - Drawing a page

    private static func draw(_ page: some View, scheme: ColorScheme, frame: Frame, settle: TimeInterval)
        -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }
        let hosting = UIHostingController(rootView: page)
        hosting.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        switch frame {
        case .tall(let width):
            hosting.safeAreaRegions = []
            // As tall as the page: a screen-sized hosting view drew only its last screenful.
            let tall = CGSize(width: width, height: .greatestFiniteMagnitude)
            var height = hosting.sizeThatFits(in: tall).height.rounded(.up)
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
        case .screen:
            window.frame = scene.screen.bounds
            window.rootViewController = hosting
            window.isHidden = false
            window.layoutIfNeeded()
            turn(settle)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            switch frame {
            case .tall:
                window.layer.render(in: context.cgContext)
            case .screen:
                // A screen's scrolling content, its ground and its glass are composited by the render
                // server, and `layer.render` drew them black: the window is drawn as it is on screen.
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    /// Lets the main run loop turn, so SwiftUI commits its state and layout.
    private static func turn(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The approved picture, where SnapshotTesting wrote it when recording: beside the suite's file,
    /// in a folder named after it.
    private static func reference(file: StaticString, testName: String, name: String) -> URL {
        let test = testName.replacingOccurrences(of: "()", with: "")
        let suite = URL(fileURLWithPath: "\(file)")
        let folder = suite.deletingPathExtension().lastPathComponent
        return suite.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/\(folder)/\(test).\(name).png")
    }

    // MARK: - Where a picture differs

    /// The comparison: a pixel differs when a channel moves by more than 8 of 255, and the page
    /// differs when more than this share of its pixels do. Two settled draws of the same page still
    /// disagree on a few photo edges and glyph fringes (about 0.1–0.4%); a tint, a frost band, a line
    /// height or a missing element moves far more.
    private static let tolerance = 0.5

    private struct Difference {
        let `where`: String
        let isBeyondTolerance: Bool
    }

    /// Which rows of the page changed, in pixels, so a failure in CI says where to look without the
    /// result bundle. Nil when nothing differs.
    private static func whereItDiffers(_ image: UIImage, from reference: URL, skippingBottom: Int) -> Difference? {
        guard let old = UIImage(contentsOfFile: reference.path) else {
            return Difference(where: "the picture could not be read", isBeyondTolerance: true)
        }
        guard let new = pixels(image), let was = pixels(old) else {
            return Difference(where: "could not read the pixels", isBeyondTolerance: true)
        }
        guard new.width == was.width, new.height == was.height else {
            return Difference(where: "size \(new.width)x\(new.height) px, picture \(was.width)x\(was.height) px",
                              isBeyondTolerance: true)
        }
        var rows: [Int] = []
        var total = 0
        let judged = max(0, new.height - skippingBottom)
        for row in 0..<judged {
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
        let share = Double(total) / Double(new.width * max(judged, 1)) * 100
        let list = bands.prefix(12).map { "\($0.from)-\($0.to)" }.joined(separator: ", ")
        let text = String(format: "%.2f%% of pixels, in %d band(s) of rows: %@%@",
                          share, bands.count, list, bands.count > 12 ? ", …" : "")
        return Difference(where: text, isBeyondTolerance: share > tolerance)
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
