import SwiftUI
import UIKit

/// **The left-edge swipe back, on a stack whose bar is hidden.**
///
/// Every pushed page draws its own back chevron, so the stack runs with the system bar hidden — and
/// UIKit's edge-pan pop refuses to begin when the navigation bar is hidden: its default delegate is
/// the navigation controller's own, which says no. This hands the recogniser a delegate that says
/// yes whenever there is something to go back to and no transition is already running, and leaves
/// the bar hidden. Native pop, native feel, native cancel-halfway.
extension View {
    func ateSwipeBack() -> some View {
        background(SwipeBackInstaller().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct SwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Installer { Installer() }
    func updateUIViewController(_ controller: Installer, context: Context) {}

    /// Re-asserted on every appearance: SwiftUI rebuilds its navigation controller's configuration
    /// when the stack changes, and a delegate set once can be quietly replaced.
    final class Installer: UIViewController {
        private let gate = SwipeBackGate()

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        private func install() {
            guard let navigation = navigationController,
                  let pop = navigation.interactivePopGestureRecognizer else { return }
            gate.navigation = navigation
            if pop.delegate !== gate { pop.delegate = gate }
            pop.isEnabled = true
        }
    }
}

/// Lets the edge pan begin when a pop is possible — and only then, because a pop gesture on the
/// root, or mid-transition, is how a navigation controller wedges itself.
private final class SwipeBackGate: NSObject, UIGestureRecognizerDelegate {
    weak var navigation: UINavigationController?

    func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
    }

    /// A horizontal scroller under the edge — the statement's month deck — waits for the edge pan to
    /// fail first, as it does under a visible bar. The edge pan fails the instant a touch starts
    /// anywhere but the edge, so nothing else waits on it, and taps never do.
    func gestureRecognizer(
        _ recogniser: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }
}
