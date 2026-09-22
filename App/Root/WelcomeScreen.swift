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
                .frame(maxHeight: .infinity, alignment: .top)
            if canSignIn {
                button
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateAccentGround(AteColor.coral)
    }

    /// The printed slip, tilted, with two photos escaping from behind it — the design's own
    /// composition, down to the angles and the overhangs.
    private var slip: some View {
        paper
            .rotationEffect(.degrees(-2.5))
            .background(alignment: .topTrailing) {
                photo("Photos/pizza", side: 150, angle: 10)
                    .offset(x: 44, y: -64)
            }
            .background(alignment: .bottomLeading) {
                photo("Photos/burger", side: 136, angle: -12)
                    .offset(x: -44, y: 50)
            }
            .padding(.horizontal, 50)
            .padding(.top, 150)
    }

    private func photo(_ name: String, side: CGFloat, angle: Double) -> some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous)
                    .strokeBorder(AteColor.coral, lineWidth: AteMetrics.photoRing)
                    .padding(-AteMetrics.photoRing)
            }
            .rotationEffect(.degrees(angle))
            .accessibilityHidden(true)
    }

    private var paper: some View {
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
    }

    /// The artboard's pill is lettered "Sign in with Apple". This build's only door is the seeded
    /// staging account (Sign in with Apple is milestone 2), and a pill that promises Apple's sheet
    /// and opens something else is worse than a pill with a shorter name. The *drawing* is the
    /// artboard's: ink, white lettering, 56 tall, full width.
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
