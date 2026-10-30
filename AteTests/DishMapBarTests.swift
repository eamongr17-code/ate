import AteKit
import MapKit
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
        // Pushed, then Search here comes in after a beat, with the page's own fade. A slow runner can
        // take longer than a fixed wait (nightly drive, 30 Oct), so wait for it, up to a limit.
        turn(2)
        for _ in 0..<16 where Self.titleView(in: window)?.window == nil {
            turn(0.25)
        }

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

    /// The real map page, opened from the Feed on the preview data, never offers Search here before
    /// anything has moved it (the nightly drive of 27 Oct found it up on opening). Sampled through the
    /// opening, so a flash counts as well as a button that stays.
    func testTheMapOpensWithoutSearchHere() throws {
        guard let environment = try? AteEnvironment.resolve(bundle: .main) else {
            XCTFail("The test host has no environment (Config/Secrets.xcconfig)")
            return
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let app = AppModel(services: AteServices(environment: environment))
        let shell = TabShell(app: app, start: V2Launch.Start(tab: .feed, path: [.map])).environment(app.gate)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: shell)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var timeline: [String] = []
        var everShown = false
        for tick in 1...24 {
            turn(0.25)
            let pushed = (window.rootViewController?.allChildren ?? [])
                .compactMap { $0 as? UINavigationController }
                .filter { $0.viewControllers.count > 1 && $0.view.window != nil }
            let title = pushed.first?.topViewController?.navigationItem.titleView
            let shown = title.map { $0.window != nil && !$0.isHiddenInTree && $0.bounds.width > 60 } ?? false
            everShown = everShown || shown
            timeline.append("\(Double(tick) * 0.25)s: \(pushed.isEmpty ? "no map" : shown ? "SHOWN" : "-")")
            if tick % 4 == 0, let map = window.allSubviews.compactMap({ $0 as? MKMapView }).first {
                let region = map.region
                timeline.append(String(
                    format: "[map %.0fx%.0f insets t%.0f b%.0f, centre %.4f,%.4f span %.4f x %.4f]",
                    map.bounds.width, map.bounds.height, map.safeAreaInsets.top, map.safeAreaInsets.bottom,
                    region.center.latitude, region.center.longitude, region.span.latitudeDelta,
                    region.span.longitudeDelta
                ))
            }
        }
        let listed = MapBox.around(SearchOrigin(latitude: -37.8118, longitude: 144.9629), radiusMeters: 2_000)
        let wanted = String(format: "listed centre %.4f,%.4f span %.4f x %.4f", listed.centerLatitude,
                            listed.centerLongitude, listed.latitudeDelta, listed.longitudeDelta)
        XCTAssertFalse(everShown,
                       "Search here showed while the map opened (\(wanted)): \(timeline.joined(separator: ", "))")
    }

    /// The pushed page's bar middle item, once the bar is up.
    private static func titleView(in window: UIWindow) -> UIView? {
        (window.rootViewController?.allChildren ?? [])
            .compactMap { $0 as? UINavigationController }.first?
            .topViewController?.navigationItem.titleView
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
