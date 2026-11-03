import SwiftUI

/// **The touch dot** — the soft circle the onboarding cards show where a finger would be: it lands
/// on a key, presses it, and lifts off, the way an iPhone screen recording shows touches
/// (`onboarding-finger.html` A, Eamon 3 Nov). Only the cards draw it; nothing in it is tappable.
///
/// A key marks where the dot can land with ``SwiftUICore/View/ateTouchTarget(_:)``; the view over
/// them draws it with ``SwiftUICore/View/ateTouchDot(_:)``, which finds the target by anchor, so the
/// dot follows the kit's own layout rather than numbers kept beside it.
enum AteTouchTarget: Hashable {
    case photos, score, diet, code, save
}

/// Where the dot is and whether it is pressing. No target: the dot has lifted off.
struct AteTouch: Equatable {
    var target: AteTouchTarget?
    var isDown = false
}

extension EnvironmentValues {
    /// The onboarding Share card's slip marks its first bookmark as the ``AteTouchTarget/save``
    /// target. Off everywhere else, so a real Feed carries no anchors.
    @Entry var ateMarksSaveTarget = false
}

private struct AteTouchTargets: PreferenceKey {
    typealias Value = [AteTouchTarget: Anchor<CGRect>]
    static var defaultValue: Value { [:] }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        // The first wins: the Share card's first bookmark is the one saved.
        value.merge(nextValue()) { first, _ in first }
    }
}

extension View {
    /// Marks this view as where the dot lands for `target`; `nil` marks nothing.
    func ateTouchTarget(_ target: AteTouchTarget?) -> some View {
        anchorPreference(key: AteTouchTargets.self, value: .bounds) { anchor in
            target.map { [$0: anchor] } ?? [:]
        }
    }

    /// Draws the dot over this view, on whichever of its targets `touch` names.
    func ateTouchDot(_ touch: AteTouch) -> some View {
        overlayPreferenceValue(AteTouchTargets.self) { anchors in
            GeometryReader { proxy in
                AteTouchDotLayer(touch: touch, frames: anchors.mapValues { proxy[$0] })
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct AteTouchDotLayer: View {
    let touch: AteTouch
    let frames: [AteTouchTarget: CGRect]

    /// The last place it landed: kept while it fades, so it lifts off where it was.
    @State private var shown: AteTouchTarget?
    /// Counts presses: each one sends out one ripple.
    @State private var presses = 0
    @Environment(\.atePalette) private var palette

    var body: some View {
        let frame = (touch.target ?? shown).flatMap { frames[$0] } ?? .zero
        let isVisible = touch.target != nil
        ZStack {
            // The ripple: once per press, it leaves the dot and fades. Unseen at rest.
            Circle()
                .strokeBorder(palette.fg.opacity(AteTouchDotMetrics.ringOpacity), lineWidth: AteTouchDotMetrics.ring)
                .keyframeAnimator(initialValue: Ripple(), trigger: presses) { ring, ripple in
                    ring.scaleEffect(ripple.scale).opacity(ripple.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1, duration: 0)
                        CubicKeyframe(AteTouchDotMetrics.rippleScale, duration: AteTouchDotMetrics.rippleDuration)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0)
                        CubicKeyframe(0, duration: AteTouchDotMetrics.rippleDuration)
                    }
                }
            Circle()
                .fill(palette.fg.opacity(AteTouchDotMetrics.fillOpacity))
                .overlay {
                    Circle().strokeBorder(
                        palette.fg.opacity(AteTouchDotMetrics.ringOpacity), lineWidth: AteTouchDotMetrics.ring
                    )
                }
                .scaleEffect(touch.isDown ? AteTouchDotMetrics.pressScale : 1)
                .animation(AteTouchDotMetrics.press, value: touch.isDown)
        }
        .frame(width: AteTouchDotMetrics.size, height: AteTouchDotMetrics.size)
        .scaleEffect(isVisible ? 1 : AteTouchDotMetrics.liftScale)
        .opacity(isVisible ? 1 : 0)
        .animation(AteTouchDotMetrics.land, value: isVisible)
        // After the animation, so the dot is placed, never slid: it lands where the key is.
        .position(x: frame.midX, y: frame.midY)
        .transaction { $0.animation = nil }
        .onChange(of: touch.target) { _, target in
            if let target { shown = target }
        }
        .onChange(of: touch.isDown) { _, isDown in
            if isDown { presses += 1 }
        }
    }
}

/// The ripple's frame: at rest it is unseen.
private struct Ripple {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

enum AteTouchDotMetrics {
    /// A fingertip's size on glass.
    static let size: CGFloat = 44
    static let ring: CGFloat = 2
    static let fillOpacity: Double = 0.22
    static let ringOpacity: Double = 0.45
    static let pressScale: CGFloat = 0.8
    static let rippleScale: CGFloat = 1.9
    /// Lands from a little larger, as a finger coming down to the glass.
    static let liftScale: CGFloat = 1.3
    static let press = Animation.easeOut(duration: 0.12)
    static let rippleDuration: TimeInterval = 0.45
    static let land = Animation.easeOut(duration: 0.22)
}
