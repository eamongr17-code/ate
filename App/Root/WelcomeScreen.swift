import SwiftUI

/// **`Welcome`** — the coral ground, the wordmark printed on a tilted slip, and one way in.
///
/// Sign in with Apple is milestone 2. Until it lands the only session available is the seeded staging
/// demo account (`DebugStagingSignIn`), which exists in Debug and Beta only — so a build with no
/// sign-in path shows the slip and no button rather than a door that cannot open.
struct WelcomeScreen: View {
    /// False in a build with no sign-in path at all (Release, or a non-staging environment).
    let canSignIn: Bool
    var isBusy = false
    let onSignIn: () async -> Void

    var body: some View {
        ZStack {
            slip
                .frame(maxHeight: .infinity, alignment: .center)
            if canSignIn {
                button
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateAccentGround(AteColor.coral)
    }

    private var slip: some View {
        VStack(spacing: AteMetrics.loose) {
            AteWordmark(height: 96)
            Text("A record of everything\nworth ordering.")
                .ateText(.proseQuote)
                .multilineTextAlignment(.center)
            AteDashedRule()
            AteBarcode()
            Text("Made to order")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
        }
        .padding(.top, 34)
        .padding(.horizontal, 18)
        .padding(.bottom, 18 + AteMetrics.tornEdgeHeight)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
        .rotationEffect(.degrees(-2.5))
        .padding(.horizontal, 50)
    }

    private var button: some View {
        Button {
            Task { await onSignIn() }
        } label: {
            Text(isBusy ? "Signing in…" : "Sign in")
                .ateText(.button)
                .frame(maxWidth: .infinity)
                .frame(height: AteMetrics.buttonHeight)
                .background(AteColor.ink, in: .capsule)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.bottom, 40)
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeScreen(canSignIn: true, onSignIn: {})
}
#endif
