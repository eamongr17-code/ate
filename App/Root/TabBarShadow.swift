import SwiftUI
import UIKit

/// **A very light shadow under the glass tab bar** (round 4, Eamon's pick from the contrast
/// exploration) — so the bar parts from the linen without losing its translucency: no fill, no
/// stroke, nothing on the glass itself.
///
/// SwiftUI exposes no hook on the system bar, and its own layer is empty: iOS 26 draws the bar as
/// capsule "platters" (the four tabs, the `+` circle) inside it. So each platter gets a shadow cast
/// by a layer just behind it, masked to *outside* the capsule — a shadow behind translucent glass
/// would show through it and grey the glass, which is smoked, the one thing the glass must never be.
/// The layer mirrors its platter's frame, fade and hiding as the bar minimises and expands. The
/// minimised forms (48pt platters) are left alone.
extension View {
    /// Applied to each tab root; every root finds the same one layer per platter.
    func ateTabBarShadow() -> some View {
        background(TabBarShadowInstaller().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct TabBarShadowInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Installer { Installer() }
    func updateUIViewController(_ controller: Installer, context: Context) {
        controller.apply()
    }

    final class Installer: UIViewController {
        private var observations: [NSKeyValueObservation] = []
        private var observed: Set<ObjectIdentifier> = []

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            apply()
        }

        func apply() {
            guard let bar = tabBarController?.tabBar else { return }
            for platter in Self.platters(in: bar) {
                cast(under: platter)
                let key = ObjectIdentifier(platter.layer)
                guard observed.contains(key) == false else { continue }
                observed.insert(key)
                // Wherever the platter goes — resized, moved, faded or hidden — the shadow follows.
                let follow: @Sendable () -> Void = { [weak self, weak platter] in
                    MainActor.assumeIsolated {
                        guard let self, let platter else { return }
                        self.cast(under: platter)
                    }
                }
                observations += [
                    platter.layer.observe(\.bounds) { _, _ in follow() },
                    platter.layer.observe(\.position) { _, _ in follow() },
                    platter.layer.observe(\.opacity) { _, _ in follow() },
                    platter.layer.observe(\.isHidden) { _, _ in follow() }
                ]
            }
        }

        private func cast(under platter: UIView) {
            guard let layer = Self.shadowLayer(for: platter) else { return }
            let shadow = traitCollection.userInterfaceStyle == .dark ? AteShadow.tabBarDark : .tabBarLight
            let radius = min(platter.bounds.width, platter.bounds.height) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            layer.frame = platter.frame
            layer.opacity = platter.layer.opacity
            layer.isHidden = platter.isHidden
            let capsule = UIBezierPath(roundedRect: platter.bounds, cornerRadius: radius)
            layer.shadowPath = capsule.cgPath
            layer.shadowColor = UIColor(shadow.colour).cgColor
            layer.shadowOpacity = 1 // the colour carries the opacity
            layer.shadowRadius = shadow.blur / 2
            layer.shadowOffset = CGSize(width: 0, height: shadow.offsetY)
            let outside = UIBezierPath(rect: platter.bounds.insetBy(dx: -shadow.blur * 2, dy: -shadow.blur * 2))
            outside.append(capsule)
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.fillRule = .evenOdd
            mask.path = outside.cgPath
            layer.mask = mask
        }

        /// The one shadow layer behind `platter`, found by name so every tab root shares it.
        private static func shadowLayer(for platter: UIView) -> CALayer? {
            guard let host = platter.superview?.layer else { return nil }
            let name = "ate.tabbar.shadow.\(ObjectIdentifier(platter).hashValue)"
            if let existing = host.sublayers?.first(where: { $0.name == name }) { return existing }
            let layer = CALayer()
            layer.name = name
            host.insertSublayer(layer, below: platter.layer)
            return layer
        }

        private static let minimumHeight: CGFloat = 56

        /// The capsules the glass is drawn in — outermost only.
        private static func platters(in root: UIView) -> [UIView] {
            var found: [UIView] = []
            func walk(_ view: UIView) {
                if String(describing: type(of: view)).hasSuffix("PlatterView") {
                    if view.bounds.height >= minimumHeight { found.append(view) }
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            return found
        }
    }
}
