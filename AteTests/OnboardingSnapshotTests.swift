import AteKit
import SwiftUI
import XCTest
@testable import Ate

/// **The tutorial, step by step** (`mockups/onboarding-calmer.html`): each of the five steps as the
/// phone shows it once its piece has landed — the composer at its one size with the words written so
/// far, the title, the dots and Next — in light and dark. The Write step plays its words and score
/// before the picture is taken; every later step opens finished. Its motion is not covered: these pin
/// that nothing is laid out ahead of its step and the composer is the same size on every one.
@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    func testWrite() { snapshot(.write) }
    func testThought() { snapshot(.thought) }
    func testNextDish() { snapshot(.nextDish) }
    func testDetails() { snapshot(.details) }
    /// Not `testShare`: the kit has a picture by that name, and the app bundle holds every picture flat.
    func testShareStep() { snapshot(.share) }

    /// Long enough for the Write step to play its three words and its score, and the photos to load.
    private static let settle: TimeInterval = 3

    private func snapshot(
        _ card: OnboardingCard,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let screen = NavigationStack {
                OnboardingCards(onDone: { _, _ in }, handle: "eamon", first: card)
                    .ateGround()
            }
            .environment(\.colorScheme, scheme)
            let shot = SnapshotPicture.Shot(
                label: "\(card)", name: name, scheme: scheme, frame: .screen, settle: Self.settle
            )
            SnapshotPicture.check(screen, shot, file: file, testName: testName, line: line)
        }
    }
}
