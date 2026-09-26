import SwiftUI
import UIKit

/// **The tab bar comes back WITH the pop, not after it** (round 4).
///
/// Pushed pages hide the bar with `.toolbar(.hidden, for: .tabBar)`, and SwiftUI only re-reads that
/// preference once a pop has *finished* — so after a swipe back the journal sat bare for about a
/// third of a second and then the bar popped in, unanimated (measured on the simulator: pop done at
/// 22.1s, bar at 22.4s). UIKit's own `hidesBottomBarWhenPushed` would ride the transition, but
/// SwiftUI owns the push and gives no hook before it.
///
/// So the tab's root carries this: when the root is about to appear under a running transition and
/// the bar is hidden, the bar is shown at once and slid in *alongside* the transition — driven by the
/// finger on an interactive pop, by the animation on a Back tap — and on a cancelled swipe it goes
/// back to hidden, exactly where the page left it. SwiftUI's own update, arriving after, finds the
/// bar already where it wants it. With Reduce Motion the bar simply fades with the transition.
extension View {
    func ateTabBarFollowsPop() -> some View {
        background(TabBarPopSync().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct TabBarPopSync: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let tabs = tabBarController, tabs.isTabBarHidden,
                  let coordinator = transitionCoordinator ?? navigationController?.transitionCoordinator,
                  // Only a pop lands on the root with a transition running under it.
                  let root = navigationController?.viewControllers.first,
                  coordinator.viewController(forKey: .to) === root else { return }
            let bar = tabs.tabBar
            let travel = UIAccessibility.isReduceMotionEnabled ? 0 : -bar.bounds.width * 0.3
            tabs.setTabBarHidden(false, animated: false)
            bar.alpha = 0
            bar.transform = CGAffineTransform(translationX: travel, y: 0)
            coordinator.animate(alongsideTransition: { _ in
                bar.alpha = 1
                bar.transform = .identity
            }, completion: { context in
                bar.alpha = 1
                bar.transform = .identity
                // A swipe let go early: the page stays, and so does its hidden bar.
                if context.isCancelled { tabs.setTabBarHidden(true, animated: false) }
            })
        }
    }
}
