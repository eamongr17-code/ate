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
    /// Marks this view as where the dot lands for `target`; `nil` marks nothing and adds no
    /// preference at all, so a Feed row's bookmark carries nothing outside onboarding.
    func ateTouchTarget(_ target: AteTouchTarget?) -> some View {
        modifier(AteTouchTargetMark(target: target))
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

private struct AteTouchTargetMark: ViewModifier {
    let target: AteTouchTarget?

    func body(content: Content) -> some View {
        if let target {
            content.anchorPreference(key: AteTouchTargets.self, value: .bounds) { [target: $0] }
        } else {
            content
        }
    }
}

private struct AteTouchDotLayer: View {
    let touch: AteTouch
    let frames: [AteTouchTarget: CGRect]

    @Environment(\.atePalette) private var palette

    var body: some View {
        // One dot per landing, identified by its key: it fades in on the key and fades out there.
        // It never travels between keys or from anywhere else (Eamon, 4 Nov: the first build's
        // dot flew around the card), and a key that has not been laid out yet shows nothing.
        ZStack(alignment: .topLeading) {
            if let target = touch.target, let frame = frames[target] {
                dot
                    .position(x: frame.midX, y: frame.midY)
                    .transaction { $0.animation = nil }
                    .id(target)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AteTouchDotMetrics.fade, value: touch.target)
    }

    private var dot: some View {
        Circle()
            .fill(palette.fg.opacity(AteTouchDotMetrics.fillOpacity))
            .overlay {
                Circle().strokeBorder(
                    palette.fg.opacity(AteTouchDotMetrics.ringOpacity), lineWidth: AteTouchDotMetrics.ring
                )
            }
            .frame(width: AteTouchDotMetrics.size, height: AteTouchDotMetrics.size)
            .scaleEffect(touch.isDown ? AteTouchDotMetrics.pressScale : 1)
            .animation(AteTouchDotMetrics.press, value: touch.isDown)
    }
}

enum AteTouchDotMetrics {
    /// A fingertip's size on glass.
    static let size: CGFloat = 44
    static let ring: CGFloat = 1.5
    static let fillOpacity: Double = 0.18
    static let ringOpacity: Double = 0.35
    static let pressScale: CGFloat = 0.88
    static let press = Animation.easeOut(duration: 0.12)
    /// In and out, in place.
    static let fade = Animation.easeOut(duration: 0.18)
}
