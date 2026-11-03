import SwiftUI

/// **A button held down** — the filled pills and Welcome's link sink a little and dim while a finger
/// is on them, and spring back on release, so a tap is seen landing (Eamon, 3 Nov: onboarding's
/// presses felt flat). `.plain`'s own dim alone read as nothing happening. With Reduce Motion the
/// size stays put and only the dim remains.
struct AtePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && reduceMotion == false ? AtePressMetrics.scale : 1)
            .opacity(configuration.isPressed ? AtePressMetrics.opacity : 1)
            .animation(AtePressMetrics.motion, value: configuration.isPressed)
    }
}

enum AtePressMetrics {
    static let scale: CGFloat = 0.97
    static let opacity: Double = 0.8
    static let motion = Animation.spring(duration: 0.2, bounce: 0.3)
}

extension ButtonStyle where Self == AtePressStyle {
    static var atePress: AtePressStyle { AtePressStyle() }
}
