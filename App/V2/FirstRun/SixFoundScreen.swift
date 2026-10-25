import AteKit
import SwiftUI

/// **You found the 6** — once, over the shell, when the composer closes on the first entry holding a
/// 6 (Eamon, 25 Oct). The onboarding's own door: the 6's token, one line, one sentence, one pill.
/// It is the only place the app says the 6 exists or that there are two in any two months.
struct SixFoundScreen: View {
    let onDone: () -> Void

    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOut = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            AteScoreToken(.personal(.blownAway), size: .hero)
                .scaleEffect(SixFoundMetrics.tokenScale)
                .rotationEffect(.degrees(SixFoundMetrics.tilt))
                .scaleEffect(isOut || reduceMotion ? 1 : 0.4)
                .opacity(isOut || reduceMotion ? 1 : 0)
                .frame(height: SixFoundMetrics.tokenHeight)
                .accessibilityHidden(true)
                .padding(.bottom, SixFoundMetrics.tokenToTitle)
            VStack(spacing: AteMetrics.snug) {
                AteTitle(text: SixFoundCopy.title, style: .handleTitle)
                Text(SixFoundCopy.line)
                    .ateText(.onboardingLine)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, OnboardingMetrics.titleInset)
            Spacer(minLength: AteMetrics.section)
            AteInkPill(title: SixFoundCopy.done, identifier: "sixfound.done", action: onDone)
                .padding(.horizontal, AteMetrics.gutter)
                .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateGround()
        .accessibilityIdentifier("v2.sixfound")
        .onAppear {
            AteHaptics.blownAway()
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) { isOut = true }
        }
    }
}

enum SixFoundCopy {
    static let title = "You found the 6."
    static let line = "Save it for a dish that blows you away. You get two every two months."
    static let done = "Got it"
}

enum SixFoundMetrics {
    /// The hero token, drawn at a little over twice its size and tilted like a sticker.
    static let tokenScale: CGFloat = 2.2
    static let tilt: Double = -4
    static let tokenHeight: CGFloat = 96
    static let tokenToTitle: CGFloat = 34
}
