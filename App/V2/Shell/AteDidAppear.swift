import SwiftUI
import UIKit

extension View {
    /// Runs `action` once the page is fully on screen: after its push has finished, not as it starts
    /// (`onAppear` fires at the start). A sheet raised from `onAppear` on a page being pushed can be
    /// refused by UIKit mid-transition, and SwiftUI then never shows it though its flag stays set
    /// (the nightly simulator run of 1 Nov: a new list's picker never rose).
    func ateOnDidAppear(_ action: @escaping () -> Void) -> some View {
        background(DidAppearHook(action: action).allowsHitTesting(false).accessibilityHidden(true))
    }
}

/// A view-less child controller: UIKit forwards the page's appearance to it, so its
/// `viewDidAppear` is the page's, once the transition into it has completed.
private struct DidAppearHook: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.action = action
    }

    final class Controller: UIViewController {
        var action: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            action?()
        }
    }
}
