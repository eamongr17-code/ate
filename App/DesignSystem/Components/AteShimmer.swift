import SwiftUI
import UIKit

/// **One sweep of light across a special score pill** (`ScoreStyle.shimmers`, round 4 exploration
/// B and C). It runs once, the first time the pill is seen, and never loops — this is a moment, not a
/// loading state (the house rule against shimmering skeletons is untouched). Reduce Motion: none.
enum AteShimmer {
    static let duration: Double = 0.9
    /// The band of light: white at 55% at its heart, feathered to nothing.
    static let peak: Double = 0.55
    /// The band's width, as a fraction of the pill's.
    static let band: CGFloat = 0.45

    /// The sweep over a pill drawn inside a text view (the composer's pills are attachments, so the
    /// light is a layer laid over the attachment's rect for the length of the sweep).
    @MainActor
    static func sweep(over rect: CGRect, in view: UIView) {
        guard UIAccessibility.isReduceMotionEnabled == false, rect.isEmpty == false else { return }
        let host = UIView(frame: rect)
        host.isUserInteractionEnabled = false
        host.layer.cornerRadius = rect.height / 2
        host.layer.cornerCurve = .continuous
        host.clipsToBounds = true
        let light = CAGradientLayer()
        light.colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: peak).cgColor,
                        UIColor(white: 1, alpha: 0).cgColor]
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        let width = max(rect.width * band, rect.height)
        light.frame = CGRect(x: -width, y: 0, width: width, height: rect.height)
        host.layer.addSublayer(light)
        view.addSubview(host)

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width / 2
        move.toValue = rect.width + width / 2
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { host.removeFromSuperview() }
        light.add(move, forKey: "sweep")
        light.position.x = rect.width + width / 2
        CATransaction.commit()
    }
}

private struct ShimmerOnce: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if isOn, reduceMotion == false {
                GeometryReader { proxy in
                    let width = max(proxy.size.width * AteShimmer.band, proxy.size.height)
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(AteShimmer.peak), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: width)
                    .offset(x: phase < 0 ? -width : proxy.size.width)
                }
                .clipShape(.capsule)
                .allowsHitTesting(false)
                .onAppear {
                    guard phase < 0 else { return }
                    withAnimation(.easeInOut(duration: AteShimmer.duration)) { phase = 1 }
                }
            }
        }
    }
}

extension View {
    /// The one-shot sweep, for a pill drawn as a live view.
    func ateShimmerOnce(_ isOn: Bool) -> some View {
        modifier(ShimmerOnce(isOn: isOn))
    }
}
