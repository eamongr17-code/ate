import AteKit
import AuthenticationServices
import SwiftUI

/// **`Welcome`** — the coral ground, the wordmark printed on a tilted slip, and two ways in: Sign in
/// with Apple, or straight to the feed to see what everyone's eating.
///
/// It is also the sign-in *prompt*: when a signed-out browser tries to write or save, this is the
/// screen that comes up, because it is the one that already asks the question. There is no second
/// "please sign in" sheet, and no copy explaining why — design rule 1. As the prompt, its link reads
/// "Not now": the person is already seeing what everyone's eating, and is being asked to stop.
///
/// A sign-in that fails (not one the person closed) says so, once, in the app's one failure alert.
struct WelcomeScreen: View {
    /// True when this is the ask over the signed-out feed, rather than the front door.
    var isPrompt = false
    /// What Apple's button came back with, and the raw nonce its request was made with. Returns
    /// false when the sign-in failed in a way worth telling the person.
    let onSignIn: (Result<ASAuthorization, any Error>, String) async -> Bool
    /// "See what everyone's eating" — the signed-out way in; "Not now" when this is the prompt.
    let onBrowse: () -> Void
    /// The seeded staging account. Non-nil only in Debug and Beta.
    var onDebugSignIn: (() async -> Void)?
    var isBusy = false

    /// The raw nonce of the request in the air. Its hash went to Apple; this goes to Supabase.
    @State private var nonce = ""
    @State private var failure: ActionFailure?

    var body: some View {
        ZStack {
            slip
                .frame(maxHeight: .infinity, alignment: .top)
            doors
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { debugDoor }
        .ateAccentGround(AteColor.coral)
        .ateFailureAlert($failure)
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
            // `margin:150px 50px 0` — from the top of the page, not from under the status bar.
            .ateContentTop(150)
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
                .foregroundStyle(AtePalette.slip.muted)
        }
        .padding(.top, 34)
        .padding(.horizontal, 18)
        .padding(.bottom, 18 + AteMetrics.tornEdgeHeight)
        // The receipt palette, like every receipt Ate prints: white in light, and in dark the plum
        // slip with light type — the same slip `Share` prints on the same coral (DESIGN.md), not
        // the dimmed linen paper, which read as a hole in the page.
        .ateSlip()
        .ateTornPaper()
    }

    /// `left:20; right:20; bottom:40; gap:6` — the pill, then the link.
    private var doors: some View {
        VStack(spacing: 6) {
            appleButton
            Button(action: onBrowse) {
                // `text-underline-offset:4px` is 4 below the BASELINE, and SwiftUI's `.underline()`
                // draws at the face's own underline position with no way to move it. Bricolage's
                // descender at 15pt is ~3.3, so a 1pt rule one point under the text box lands where
                // the markup puts it — and, unlike `.underline()`, it is the design's hairline.
                //
                // The rule hangs off the text as an overlay rather than stacking under it, so it is
                // the text's own width without pinning the text to one line: at the accessibility
                // sizes a one-line link was wider than the phone and dragged the whole page with it.
                Text(isPrompt ? "Not now" : "See what everyone's eating")
                    .ateText(.control)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(AteColor.ink).frame(height: 1)
                    }
                    .frame(minHeight: AteMetrics.hit)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AteColor.ink)
            .accessibilityIdentifier("welcome.browse")
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(40)
    }

    /// **Apple's own button** — App Review requires the official `SignInWithAppleButton`, with
    /// Apple's logo and lettering, so it stands where the artboard's hand-lettered ink pill stood:
    /// the same 56 height, full width, and the same capsule (Apple permits the corner radius). Its
    /// type is Apple's, not Bricolage — the one control in the app whose face is not ours to set.
    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = AppleSignIn.prepare(request)
        } onCompletion: { result in
            let requested = nonce
            Task {
                if await onSignIn(result, requested) == false { failure = .signIn }
            }
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: AteMetrics.buttonHeight)
        .clipShape(.capsule)
        .opacity(isBusy ? 0.6 : 1)
        .disabled(isBusy)
        .accessibilityIdentifier("welcome.signIn")
    }

    /// The seeded staging account, in Debug and Beta only. It sits in the top corner, clear of
    /// everything the artboard draws, so it cannot move any of it — and it disappears entirely in a
    /// Release build — and under `-ate-hide-debug-door`, which is how the parity screenshot is taken
    /// of exactly what ships.
    @ViewBuilder
    private var debugDoor: some View {
        if let onDebugSignIn, SettingsDebugLaunch.showsDebugDoor {
            Button {
                Task { await onDebugSignIn() }
            } label: {
                Text(verbatim: "staging")
                    .ateText(.meta)
                    .foregroundStyle(AteColor.ink.opacity(0.45))
                    .frame(minWidth: AteMetrics.hit, minHeight: AteMetrics.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, AteMetrics.regular)
            .ateContentTop()
            .accessibilityIdentifier("welcome.debugSignIn")
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeScreen(onSignIn: { _, _ in true }, onBrowse: {})
}
#endif
