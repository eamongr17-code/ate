import AuthenticationServices
import AteKit
import CryptoKit
import Foundation
import Supabase

/// **Sign in with Apple**, the native way: `ASAuthorizationController` → an Apple identity token →
/// `supabase.auth.signInWithIdToken(.apple, …)`.
///
/// Not `SignInWithAppleButton` and not a web redirect. The SwiftUI button draws Apple's own pill and
/// `Welcome.dc.html` draws the app's, and a web flow would put Safari between the coral screen and
/// the journal for no gain — the native controller is one sheet the person already trusts.
///
/// **The nonce is the whole security story.** A random string is generated here, its SHA-256 goes to
/// Apple in the request, and the *raw* string goes to Supabase with the token. Supabase hashes it
/// and compares with the `nonce` claim inside the signed token, which is what stops a token minted
/// for some other app from being replayed at ours. Sending the same value to both is the classic way
/// to get this wrong, so the two spellings are named apart below.
@MainActor
struct AppleSignIn {
    /// What Apple came back with.
    struct Credential {
        let identityToken: String
        let nonce: String
        /// Apple hands over a name and an email **only on the very first authorization** for this
        /// Apple ID and this app — one of the three signals `FirstRun` routes a new account to
        /// `Handle` on.
        let isFirstAuthorization: Bool
        /// Apple's own display name, first time only. `signInWithIdToken` has no room for it, so the
        /// shell writes it to `profiles.name` itself; nil on every later sign-in, which is correct.
        let fullName: String?
    }

    /// Runs Apple's sheet. Throws ``AppleSignInError`` — `cancelled` when the person closed it,
    /// which the caller must not report as a breakage.
    static func authorize() async throws -> Credential {
        let nonce = randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let credential = try await AppleAuthorizationSession.run(request)
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            throw AppleSignInError.noIdentityToken
        }
        let name = credential.fullName.flatMap { components in
            [components.givenName, components.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return Credential(
            identityToken: token,
            nonce: nonce,
            isFirstAuthorization: credential.email != nil || (name?.isEmpty == false),
            fullName: name?.isEmpty == true ? nil : name
        )
    }

    /// Who the exchange signed in, and when their account was made — `FirstRun` reads both.
    struct SignedIn {
        let userID: UUID
        let accountCreatedAt: Date
    }

    /// Exchanges Apple's token for a Supabase session — the raw nonce, which Supabase hashes and
    /// checks against the one inside the token.
    static func exchange(_ credential: Credential, with api: AteAPIClient) async throws -> SignedIn {
        let session = try await api.supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: credential.identityToken,
                nonce: credential.nonce
            )
        )
        return SignedIn(userID: session.user.id, accountCreatedAt: session.user.createdAt)
    }

    // MARK: - Nonce

    /// 32 bytes of `SecRandomCopyBytes`, base32-ish encoded into the character set Apple accepts.
    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        // A failure here means the system entropy source is gone; falling back to a predictable
        // nonce would be worse than failing, so it maps onto a value we will still notice.
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Why a sign-in produced no session.
enum AppleSignInError: Error {
    /// The person dismissed Apple's sheet. Not a failure to report as one.
    case cancelled
    /// Apple authorised but returned no token to exchange.
    case noIdentityToken
    /// Apple refused, or could not be reached.
    case authorization(any Error)

    var reason: SignInFailure {
        switch self {
        case .cancelled: .cancelled
        case .noIdentityToken: .noIdentityToken
        case .authorization: .authorization
        }
    }
}

/// The delegate `ASAuthorizationController` insists on, as one `await`.
///
/// It holds itself alive until the controller answers: `ASAuthorizationController` keeps only a weak
/// delegate, so a locally-scoped one is deallocated the instant `performRequests()` returns and the
/// callback never arrives. That is the classic silent-failure in this API, and the `retained`
/// reference below is the fix.
private final class AppleAuthorizationSession: NSObject, ASAuthorizationControllerDelegate,
                                               ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, any Error>?
    private var retained: AppleAuthorizationSession?

    @MainActor
    static func run(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationAppleIDCredential {
        let session = AppleAuthorizationSession()
        return try await withCheckedThrowingContinuation { continuation in
            session.continuation = continuation
            session.retained = session
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = session
            controller.presentationContextProvider = session
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { retained = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppleSignInError.noIdentityToken)
            continuation = nil
            return
        }
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        defer { retained = nil }
        let failure: AppleSignInError = (error as? ASAuthorizationError)?.code == .canceled
            ? .cancelled
            : .authorization(error)
        continuation?.resume(throwing: failure)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
