import AteKit
import AuthenticationServices
import SwiftUI

/// **Welcome** — a full-screen cover on coral: the logo traced on, five stars and the line
/// (``AteWelcomeMark``), then Apple's own Sign in with Apple in black and "See what everyone's
/// eating", which opens the Feed signed out. "Continue with email" sits under Apple's button and
/// pushes the email sign-in (``V2EmailSignInScreen``).
///
/// It is also the sign-in ask: when somebody reading signed out tries to write or save, this is the
/// screen that comes up, and its link reads "Not now". A sign-in that fails (not one the person
/// closed) says so, once.
struct V2WelcomeScreen: View {
    /// True when this is the ask over the signed-out feed, rather than the front door.
    var isPrompt = false
    /// What Apple's button came back with, and the raw nonce its request was made with. Returns
    /// false when the sign-in failed in a way worth telling the person.
    let onSignIn: (Result<ASAuthorization, any Error>, String) async -> Bool
    /// "See what everyone's eating" — or "Not now" when this is the ask.
    let onBrowse: () -> Void
    /// The seeded staging account. Non-nil only in Debug and Beta.
    var onDebugSignIn: (() async -> Void)?
    /// "Continue with email": a code to the address, then the code for a session (``V2EmailSignInScreen``).
    var onSendEmailCode: (String) async -> Bool = { _ in false }
    var onEmailCode: (String, String) async -> Bool = { _, _ in false }
    var isBusy = false

    /// The raw nonce of the request in the air. Its hash went to Apple; this goes to Supabase.
    @State private var nonce = ""
    @State private var failure: ActionFailure?
    @State private var showsEmail = false

    var body: some View {
        NavigationStack {
            welcome
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showsEmail) {
                    V2EmailSignInScreen(onSendCode: onSendEmailCode, onVerify: onEmailCode)
                }
        }
    }

    private var welcome: some View {
        // Stacked rather than layered, so however tall the type makes either part they cannot
        // overlap: at the largest sizes the page scrolls, Apple's button always clear of the mark
        // (App Review reads an obscured Sign in with Apple as a rejection).
        ViewThatFits(in: .vertical) {
            page
            ScrollView { page }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { debugDoor }
        .accessibilityIdentifier("v2.welcome")
        .ateAccentGround(AteColor.coral)
        .ateFailureAlert($failure)
    }

    private var page: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            AteWelcomeMark()
            Spacer(minLength: AteMetrics.section)
            doors
        }
    }

    /// Apple's button, the email one under it, then the link.
    private var doors: some View {
        VStack(spacing: AteWelcomeCardMetrics.doorsGap) {
            VStack(spacing: AteWelcomeCardMetrics.buttonsGap) {
                appleButton
                AteWelcomeEmailButton(isEnabled: isBusy == false) { showsEmail = true }
            }
            AteWelcomeLink(title: isPrompt ? "Not now" : "See what everyone's eating", action: onBrowse)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
    }

    /// **Apple's own button** — App Review requires the official one, with Apple's logo and
    /// lettering, full width in a capsule. Its type is Apple's: the one control whose face is not ours.
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
        .opacity(isBusy ? AteKitColor.disabledOpacity : 1)
        .disabled(isBusy)
        .accessibilityIdentifier("welcome.signIn")
    }

    /// The seeded staging account, in Debug and Beta only, in the top corner clear of everything the
    /// design draws — and hidden for a parity screenshot of exactly what ships.
    @ViewBuilder
    private var debugDoor: some View {
        if let onDebugSignIn, SettingsDebugLaunch.showsDebugDoor {
            Button {
                Task { await onDebugSignIn() }
            } label: {
                Text(verbatim: "staging")
                    .ateText(.meta)
                    .frame(minWidth: AteMetrics.hit, minHeight: AteMetrics.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AtePalette.automatic.muted)
            .padding(.trailing, AteMetrics.regular)
            .accessibilityIdentifier("welcome.debugSignIn")
        }
    }
}
