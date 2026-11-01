import Foundation

/// **Email sign-in, the parts with rules** — what counts as an address worth sending a code to, what
/// counts as a code, and when "Send a new code" may be pressed again. The app's screens and the
/// Supabase calls (`signInWithOTP` / `verifyOTP`) sit on top of these (`App/Root/EmailSignIn.swift`).
///
/// One path for everyone (Eamon, 1 Nov 2026, option A): type your email, then the 6-digit code we
/// send. A new address becomes an account only once its code is typed (Confirm email stays on); an
/// address already used with Sign in with Apple signs into that same account.
public enum EmailSignInRules {
    /// The code's length — the server's `mailer_otp_length` (`.github/scripts/auth_setup.sh`).
    public static let codeLength = 6
    /// How long before another code may be asked for — the server's `smtp_max_frequency`.
    public static let resendWait: TimeInterval = 60
    /// Longest address accepted (RFC 5321's path limit).
    public static let maxAddressLength = 254

    /// The address as it is sent: trimmed and lowercased. `nil` when it cannot be an address —
    /// nothing is sent for it, and Continue stays dimmed.
    public static func address(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count <= maxAddressLength,
              trimmed.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s.]{2,}/) != nil else { return nil }
        return trimmed
    }

    /// What was typed (or pasted, or filled from Mail) into the code boxes, as the code: its digits,
    /// at most ``codeLength`` of them. "482 913" and "482-913" are the code too.
    public static func code(_ typed: String) -> String {
        String(typed.filter(\.isASCIIDigit).prefix(codeLength))
    }

    /// The code is whole: the moment to sign in, with no button.
    public static func isComplete(_ code: String) -> Bool {
        code.count == codeLength
    }

    /// Seconds left before "Send a new code" works; 0 when it does.
    public static func secondsUntilResend(sentAt: Date, now: Date = Date()) -> Int {
        max(0, Int((resendWait - now.timeIntervalSince(sentAt)).rounded(.up)))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
