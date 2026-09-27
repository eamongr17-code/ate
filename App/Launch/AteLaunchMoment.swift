import Observation
import SwiftUI

/// **The launch moment** (round 5, Eamon: the logo "should show when a user boots up the app").
///
/// The system's launch screen (`UILaunchScreen` in `Config/Info.plist`) draws the first frame — a
/// ground and the wordmark, centred — and this overlay starts on exactly that frame, so the hand-off
/// from the system to the app is invisible. Then, one of two moments (``JSExplore/launch``):
/// - **A, the logo lands** — on the linen ground, the wordmark travels from the centre to its place
///   in the Journal's header and the ground fades away around it; the header's own logo takes over
///   where it lands. Signed out, where there is no Journal, the ground simply fades.
/// - **B, the icon opens** — the app icon's coral (ink in dark) with its wordmark, which gives a
///   small press and fades away onto the app.
///
/// Reduce Motion: a plain fade either way.
@MainActor
@Observable
final class AteLaunchMoment {
    static let shared = AteLaunchMoment()

    enum Phase {
        case holding, leaving, done
    }

    /// A UI test starts on the app, not on a moment.
    var phase: Phase = ProcessInfo.processInfo.arguments.contains("-ate-ui-testing") ? .done : .holding
    /// Where the Journal header's wordmark sits on screen — the landing spot. `nil` until the
    /// Journal has laid out (and forever when signed out).
    var logoTarget: CGRect?

    /// Whether the header's own logo should hide, because the moment's copy of it is still flying.
    var hidesHeaderLogo: Bool {
        JSExplore.launch == .a && phase != .done
    }
}

extension View {
    /// Wraps the whole app in the launch moment.
    func ateLaunchMoment() -> some View {
        overlay { AteLaunchOverlay() }
    }

    /// Marks the Journal header's wordmark as where the moment's logo lands.
    func ateLaunchLogoTarget() -> some View {
        modifier(AteLaunchLogoTarget())
    }
}

private struct AteLaunchLogoTarget: ViewModifier {
    @State private var moment = AteLaunchMoment.shared

    func body(content: Content) -> some View {
        content
            .opacity(moment.hidesHeaderLogo ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                guard moment.phase == .holding, frame.minY > 0 else { return }
                moment.logoTarget = frame
            }
    }
}

private struct AteLaunchOverlay: View {
    @State private var moment = AteLaunchMoment.shared
    @State private var logoFrame: CGRect?
    @State private var groundOpacity: Double = 1
    @State private var logoOpacity: Double = 1
    @State private var logoScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let variant = JSExplore.launch
    /// The launch screen's wordmark: 64 tall, centred (`LaunchWordmarkA/B` are drawn at this size).
    static let logoHeight: CGFloat = 64
    private static let aspect: CGFloat = 758.0 / 359.0

    var body: some View {
        if moment.phase != .done {
            GeometryReader { proxy in
                let centre = CGRect(
                    x: (proxy.size.width - Self.logoHeight * Self.aspect) / 2,
                    y: (proxy.size.height - Self.logoHeight) / 2,
                    width: Self.logoHeight * Self.aspect,
                    height: Self.logoHeight
                )
                let frame = logoFrame ?? centre
                ZStack(alignment: .topLeading) {
                    ground.opacity(groundOpacity)
                    AteWordmark(height: Self.logoHeight, colour: logoColour)
                        .scaleEffect(frame.height / Self.logoHeight * logoScale, anchor: .topLeading)
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(logoOpacity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .allowsHitTesting(moment.phase == .holding)
            .accessibilityHidden(true)
            .task { await run() }
        }
    }

    private var ground: Color {
        switch variant {
        case .b: colorScheme == .dark ? AteColor.groundInk : AteColor.coral
        default: AteColor.ground
        }
    }

    private var logoColour: Color? {
        switch variant {
        case .b: colorScheme == .dark ? AteColor.coral : .white
        default: nil
        }
    }

    private func run() async {
        // The first frame is the launch screen's; hold it long enough to be seen, and — for A —
        // until the Journal has said where its logo is (never more than a second more).
        try? await Task.sleep(for: .milliseconds(450))
        if variant != .b {
            for _ in 0..<20 where moment.logoTarget == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        moment.phase = .leaving
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                groundOpacity = 0
                logoOpacity = 0
            }
        } else if variant == .b {
            withAnimation(.snappy(duration: 0.18)) { logoScale = 0.92 }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeIn(duration: 0.35)) {
                logoScale = 1.25
                logoOpacity = 0
                groundOpacity = 0
            }
        } else if let target = moment.logoTarget {
            withAnimation(.spring(duration: 0.6, bounce: 0.15)) { logoFrame = target }
            withAnimation(.easeOut(duration: 0.45).delay(0.1)) { groundOpacity = 0 }
        } else {
            withAnimation(.easeOut(duration: 0.4)) {
                groundOpacity = 0
                logoOpacity = 0
            }
        }
        try? await Task.sleep(for: .milliseconds(650))
        moment.phase = .done
    }
}
