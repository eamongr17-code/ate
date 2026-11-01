import AteKit
import Foundation
import Supabase

/// **Email sign-in** (Nov 2026, `email-signin-share-links` option A): an address, then the 6-digit
/// code Supabase sends to it from hello@<domain> (Resend SMTP, `.github/scripts/auth_setup.sh`).
///
/// One path for new and returning people. `shouldCreateUser` makes the account on the first code,
/// but it is not confirmed — and cannot be signed into — until that code comes back, so an address
/// nobody owns never becomes a usable account (Confirm email stays on). An address already on an
/// Apple sign-in is the same Supabase user, so it opens the same journal.
@MainActor
struct EmailSignIn {
    /// Asks Supabase to email a code. Throws when the address was refused, the same address asked
    /// again inside the minute (`smtp_max_frequency`), or there was no connection.
    static func sendCode(to address: String, with api: AteAPIClient) async throws {
        try await api.supabase.auth.signInWithOTP(email: address, shouldCreateUser: true)
    }

    /// Trades the code for a session. `.email` covers both a new address's confirmation code and a
    /// returning one's sign-in code.
    static func verify(
        _ code: String, for address: String, with api: AteAPIClient
    ) async throws -> AppleSignIn.SignedIn {
        let response = try await api.supabase.auth.verifyOTP(email: address, token: code, type: .email)
        guard let session = response.session else { throw EmailSignInError.noSession }
        return AppleSignIn.SignedIn(userID: session.user.id, accountCreatedAt: session.user.createdAt)
    }
}

enum EmailSignInError: Error {
    /// The code was accepted but no session came back — never expected with Confirm email on.
    case noSession
}
