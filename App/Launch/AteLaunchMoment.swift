import SwiftUI

/// **The launch moment** (round 5, Eamon: the logo "should show when a user boots up the app"; his
/// pick: the coral splash).
///
/// The system's launch screen (`UILaunchScreen` in `Config/Info.plist`: `LaunchGround`,
/// `LaunchWordmark`) draws the first frame — the app icon's coral with its white wordmark, centred;
/// ink with a coral wordmark in dark, as the icon's dark appearance is. This overlay starts on
/// exactly that frame, so the hand-off from the system to the app cannot be seen; it holds a
/// moment, the wordmark gives a small press, and the whole thing fades away onto the app.
///
/// Reduce Motion: a plain fade. A UI test starts on the app, never on the moment.
struct AteLaunchOverlay: View {
    @State private var isDone = ProcessInfo.processInfo.arguments.contains("-ate-ui-testing")
    @State private var opacity: Double = 1
    @State private var logoScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The launch screen's wordmark: 64 tall, centred (`LaunchWordmark` is drawn at this size).
    private static let logoHeight: CGFloat = 64

    var body: some View {
        if isDone == false {
            ZStack {
                (colorScheme == .dark ? AteColor.groundInk : AteColor.coral)
                AteWordmark(height: Self.logoHeight, colour: colorScheme == .dark ? AteColor.coral : .white)
                    .scaleEffect(logoScale)
            }
            .ignoresSafeArea()
            .opacity(opacity)
            .allowsHitTesting(opacity == 1)
            .accessibilityHidden(true)
            .task { await run() }
        }
    }

    private func run() async {
        // Long enough to be seen, not long enough to be waited on.
        try? await Task.sleep(for: .milliseconds(450))
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
        } else {
            withAnimation(.snappy(duration: 0.18)) { logoScale = 0.92 }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeIn(duration: 0.35)) {
                logoScale = 1.25
                opacity = 0
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        isDone = true
    }
}

extension View {
    /// Wraps the whole app in the launch moment.
    func ateLaunchMoment() -> some View {
        overlay { AteLaunchOverlay() }
    }
}
