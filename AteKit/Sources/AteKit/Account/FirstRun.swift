import Foundation

/// **Who is sent to `Handle` after signing in.** Every new account, and nobody else.
///
/// Three signals, because none of them is enough alone:
///
/// 1. **Apple's first authorization** — the only sign-in for an Apple ID and this app on which Apple
///    hands over a name or an email. Honest, but Apple only does it once per Apple ID, ever: a person
///    who deletes their account and signs up again gets nothing the second time.
/// 2. **The account is minutes old.** `auth.users.created_at` against the clock — catches that second
///    sign-up.
/// 3. **The handle is still the placeholder** `handle_new_user` minted (`ate` + 8 hex, 0032) — catches
///    a first run that was killed before anything was written down on this phone, and one finished on
///    a different phone.
public enum FirstRun {
    /// How recent an account has to be to count as being made by this sign-in. Generous, because a
    /// person can sit on Apple's sheet; short, because nobody signs back in within it by accident.
    public static let newAccountWindow: TimeInterval = 10 * 60

    public static func isNewAccount(isFirstAuthorization: Bool, createdAt: Date?, now: Date = Date()) -> Bool {
        if isFirstAuthorization { return true }
        guard let createdAt else { return false }
        return now.timeIntervalSince(createdAt) < newAccountWindow
    }
}

extension HandleName {
    /// Whether a handle is one the server made up rather than one somebody chose: `ate` and at least
    /// eight hex digits of the user id, with the collision counter the trigger appends when it has to
    /// (`ate1a2b3c4d`, `ate1a2b3c4d2`, or the whole id when twenty of those are taken).
    public static func isPlaceholder(_ handle: String) -> Bool {
        handle.wholeMatch(of: /ate[0-9a-f]{8,27}[0-9]*/) != nil
    }
}
