import SwiftUI
import UIKit
import XCTest
@testable import Ate

/// **The dish map's top bar, hosted** (build 243: "the Search here button is gone"). The map's own
/// bar (``SwiftUICore/View/feedMapBar(showsSearchHere:searchHere:recentre:)``), pushed on a real
/// navigation stack in a window: once Search here is due it must be in the bar, on screen, with
/// width, and a tap at its middle must land on it.
@MainActor
final class DishMapBarTests: XCTestCase {
    func testSearchHereIsInTheBarAndTakesTaps() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: MapBarHost())
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        // Pushed, then Search here comes in after a beat, with the page's own fade.
        turn(2)

        let bars = window.allSubviews.compactMap { $0 as? UINavigationBar }.filter { $0.window != nil }
        let bar = try XCTUnwrap(bars.first, "a navigation bar is up")
        let controllers = window.rootViewController?.allChildren ?? []
        let navigation = try XCTUnwrap(controllers.compactMap { $0 as? UINavigationController }.first)
        let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
        let tree = describe(bar)

        let title = try XCTUnwrap(item.titleView, "Search here is the bar's middle item. The bar:\n\(tree)")
        let frame = title.convert(title.bounds, to: window)
        XCTAssertNotNil(title.window, "Search here is in the window. The bar:\n\(tree)")
        XCTAssertFalse(title.isHiddenInTree, "Search here is not hidden. The bar:\n\(tree)")
        XCTAssertGreaterThan(frame.width, 60, "Search here has its width (\(frame)). The bar:\n\(tree)")
        XCTAssertTrue(window.bounds.contains(frame), "Search here is on screen (\(frame))")
        let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
        XCTAssertTrue(hit.map { $0.isDescendant(of: title) } ?? false,
                      "a tap at Search here's middle lands on it, not on \(String(describing: hit))")
    }

    private func turn(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func describe(_ view: UIView, depth: Int = 0) -> String {
        let line = String(repeating: "  ", count: depth)
            + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden) alpha=\(view.alpha)"
        guard depth < 8 else { return line }
        return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
    }
}

/// A root, with the map's bar pushed on top of it, as the Feed pushes the map.
private struct MapBarHost: View {
    @State private var path = [1]
    @State private var showsSearchHere = false

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear.navigationDestination(for: Int.self) { _ in
                Color.clear
                    .feedMapBar(showsSearchHere: showsSearchHere, searchHere: {}, recentre: {})
                    .task {
                        try? await Task.sleep(for: .milliseconds(500))
                        withAnimation(AteMotion.fillIn) { showsSearchHere = true }
                    }
            }
        }
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
    var isHiddenInTree: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return true }
            view = current.superview
        }
        return false
    }
}

private extension UIViewController {
    var allChildren: [UIViewController] { [self] + children.flatMap(\.allChildren) }
}
