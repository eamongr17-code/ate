import AteKit
import SwiftUI
import XCTest
@testable import Ate

/// **Where the onboarding touch dot lands** (``AteTouchDot``): resting on the Score key, pressing the
/// Diet key, and on the Share card's first bookmark, in light and dark. The dot finds each key by
/// anchor, so these pin that it lands on the key and not beside it. Its motion is not covered.
@MainActor
final class TouchDotSnapshotTests: XCTestCase {
    func testOnKeys() {
        for target in [AteTouchTarget.score, .diet] {
            snapshot(keys(touch: AteTouch(target: target, isDown: target == .diet)), label: "\(target)")
        }
    }

    func testOnBookmark() {
        let slip = AteEntrySlip(
            slip: OnboardingSample.feedSlip(handle: "eamon", isSaved: false),
            surface: .feed,
            onSave: { _ in }
        )
        .environment(\.ateMarksSaveTarget, true)
        .ateTouchDot(AteTouch(target: .save))
        .padding(AteMetrics.gutter)
        snapshot(slip, label: "save")
    }

    private func keys(touch: AteTouch) -> some View {
        HStack(spacing: AteMetrics.snug) {
            Spacer(minLength: 0)
            ComposerKey(
                title: "Score", icon: .starFilled, background: AteColor.scoreFill, foreground: AteColor.scoreInk
            ) {}
            .ateTouchTarget(.score)
            ComposerKey(
                title: "Diet", icon: .diet, iconSize: 16, background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk, isActive: touch.isDown, iconOnly: true
            ) {}
            .ateTouchTarget(.diet)
        }
        .padding(AteMetrics.gutter)
        .ateTouchDot(touch)
    }

    private static let width: CGFloat = 393

    private func snapshot(
        _ view: some View, label: String,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let page = view
                .frame(width: Self.width)
                .ateGround()
                .environment(\.colorScheme, scheme)
            let shot = SnapshotPicture.Shot(
                label: label, name: "\(label)-\(name)", scheme: scheme, frame: .tall(width: Self.width), settle: 1
            )
            SnapshotPicture.check(page, shot, file: file, testName: testName, line: line)
        }
    }
}
