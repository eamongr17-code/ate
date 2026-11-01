import AteKit
import SwiftUI

/// **Email sign-in** (`email-signin-share-links.html` A, approved 1 Nov 2026): pushed from Welcome's
/// "Continue with email". "Your email" and Continue, which sends the code; then "Enter the code" —
/// six boxes iOS fills from Mail, and the sixth digit signs in with no button. "Send a new code"
/// works a minute after the last one.
struct V2EmailSignInScreen: View {
    /// Sends a code to the address; false when it did not go out.
    let onSendCode: (String) async -> Bool
    /// The address and its code; false when the code did not sign in.
    let onVerify: (String, String) async -> Bool

    @State private var typed = ""
    @State private var isSending = false
    @State private var failure: ActionFailure?
    /// Set once a code went out: the page becomes "Enter the code".
    @State private var sentTo: String?
    /// When the last code went out — "Send a new code" waits a minute from it.
    @State private var sentAt = Date.distantPast

    var body: some View {
        EmailPage(
            title: "Your email",
            content: {
                AteFieldPill(label: "Email", text: $typed, identifier: "email.address", showsLabel: false)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit(send)
                AteInkPill(
                    title: "Continue",
                    isEnabled: EmailSignInRules.address(typed) != nil && isSending == false,
                    identifier: "email.continue",
                    action: send
                )
            }
        )
        .navigationDestination(item: $sentTo) { address in
            V2EmailCodeScreen(address: address, sentAt: sentAt, onResend: resend, onVerify: onVerify)
        }
        .ateFailureAlert($failure)
    }

    private func send() {
        guard let address = EmailSignInRules.address(typed), isSending == false else { return }
        isSending = true
        Task {
            let ok = await onSendCode(address)
            isSending = false
            if ok {
                sentAt = Date()
                sentTo = address
            } else {
                failure = .sendCode
            }
        }
    }

    /// "Send a new code": false when it did not go out.
    private func resend() async -> Bool {
        guard let address = sentTo else { return false }
        let ok = await onSendCode(address)
        if ok { sentAt = Date() }
        return ok
    }
}

/// "Enter the code" — the second half of ``V2EmailSignInScreen``.
struct V2EmailCodeScreen: View {
    let address: String
    let sentAt: Date
    let onResend: () async -> Bool
    let onVerify: (String, String) async -> Bool

    @State private var code = ""
    @State private var isVerifying = false
    @State private var failure: ActionFailure?
    @FocusState private var isFocused: Bool

    @Environment(\.atePalette) private var palette

    var body: some View {
        EmailPage(
            title: "Enter the code",
            content: {
                Text("Sent to \(Text(address).bold())")
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                AteCodeBoxes(code: $code, isFocused: $isFocused, isEnabled: isVerifying == false)
                resendLink
            }
        )
        .onChange(of: code) { _, now in
            if EmailSignInRules.isComplete(now) { verify(now) }
        }
        .onAppear { isFocused = true }
        .ateFailureAlert($failure)
    }

    /// Dimmed, counting down, until a minute after the last code.
    private var resendLink: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = EmailSignInRules.secondsUntilResend(sentAt: sentAt, now: context.date)
            AteWelcomeLink(
                title: wait > 0 ? "Send a new code in \(wait)s" : "Send a new code",
                colour: palette.fg,
                identifier: "email.resend"
            ) {
                Task {
                    code = ""
                    if await onResend() == false { failure = .sendCode }
                }
            }
            .disabled(wait > 0 || isVerifying)
            .opacity(wait > 0 ? AteKitColor.disabledOpacity : 1)
            .frame(maxWidth: .infinity)
        }
    }

    private func verify(_ code: String) {
        guard isVerifying == false else { return }
        isVerifying = true
        Task {
            let ok = await onVerify(address, code)
            isVerifying = false
            if ok == false {
                self.code = ""
                failure = .emailCode
            }
        }
    }
}

/// The two pages' shared frame: the handle step's title and inset, on the ground.
private struct EmailPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AteEmailSignInMetrics.gap) {
            AteTitle(text: title, style: .handleTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, AteEmailSignInMetrics.titleBottom)
            content()
        }
        .padding(.horizontal, AteHandleFieldMetrics.pageInset)
        .padding(.top, AteHandleFieldMetrics.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ateGround()
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AteEmailSignInMetrics {
    static let gap: CGFloat = 16
    static let titleBottom: CGFloat = 12
}
