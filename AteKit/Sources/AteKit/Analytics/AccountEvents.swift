import Foundation

/// How somebody got in. A closed set, because the funnel question is always "which door", and a
/// free string quietly becomes three spellings of the same one.
public enum SignInProvider: String, Sendable, CaseIterable, Codable {
    case apple
    /// The seeded staging account. Debug and Beta only — it is in the vocabulary so the numbers
    /// from an internal build can be told apart from real ones rather than silently inflating them.
    case debugStaging = "debug_staging"
}

/// **First run and Settings** — the funnel from the coral screen to a handle, and the handful of
/// things somebody does to their own account afterwards.
///
/// `sign_in_started → sign_in_completed → handle_set` is the only funnel in the app whose drop-off
/// is a *product* answer rather than a taste one: everybody who abandons it never writes anything.
/// Built here so the names and parameters are asserted by tests and can never drift.
public enum AccountEvents {

    /// The button was pressed — before Apple's sheet, so an abandoned sheet is visible as the gap
    /// between this and ``signInCompleted(provider:)``.
    public static func signInStarted(provider: SignInProvider) -> AnalyticsEvent {
        AnalyticsEvent(name: "sign_in_started", parameters: ["provider": provider.rawValue])
    }

    /// There is a session.
    public static func signInCompleted(provider: SignInProvider) -> AnalyticsEvent {
        AnalyticsEvent(name: "sign_in_completed", parameters: ["provider": provider.rawValue])
    }

    /// Apple's sheet, or the token exchange, came back with nothing. `reason` is `cancelled` when
    /// the person closed it — the difference between "changed their mind" and "it is broken" is the
    /// whole value of the event.
    public static func signInFailed(provider: SignInProvider, reason: SignInFailure) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "sign_in_failed",
            parameters: ["provider": provider.rawValue, "reason": reason.rawValue]
        )
    }

    /// "See what everyone's eating" — the signed-out door. Once per launch that takes it.
    public static func browseStarted() -> AnalyticsEvent {
        AnalyticsEvent(name: "browse_started")
    }

    /// A browser tried to write and was asked to sign in. `trigger` is which write it was.
    public static func signInPrompted(trigger: SessionGate.Trigger) -> AnalyticsEvent {
        AnalyticsEvent(name: "sign_in_prompted", parameters: ["trigger": trigger.rawValue])
    }

    /// A handle was written. `is_first_run` separates the one that completes sign-up from an edit
    /// made later in Settings.
    public static func handleSet(isFirstRun: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "handle_set", parameters: ["is_first_run": isFirstRun ? "true" : "false"])
    }

    /// Settings opened. Once per appearance.
    public static func settingsViewed() -> AnalyticsEvent {
        AnalyticsEvent(name: "settings_viewed")
    }

    /// The appearance was changed, to what.
    public static func appearanceChanged(_ appearance: AteAppearance) -> AnalyticsEvent {
        AnalyticsEvent(name: "appearance_changed", parameters: ["appearance": appearance.rawValue])
    }

    /// Somebody was unblocked from the Settings list. The block itself is
    /// ``SocialEvents/userBlocked()``, which this is the mirror of.
    public static func userUnblocked() -> AnalyticsEvent {
        AnalyticsEvent(name: "user_unblocked")
    }

    /// The session was ended deliberately.
    public static func signedOut() -> AnalyticsEvent {
        AnalyticsEvent(name: "signed_out")
    }

    /// `delete_account` took the data. `auth_user_deleted` is `false` when the login survived it —
    /// the one outcome we must hear about (it needs the admin API). Sent **before** the sign-out
    /// that follows, because after it there is nobody left to report it.
    public static func accountDeleted(authUserDeleted: Bool = true) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "account_deleted",
            parameters: ["auth_user_deleted": authUserDeleted ? "true" : "false"]
        )
    }
}

/// Why a sign-in did not produce a session.
public enum SignInFailure: String, Sendable, CaseIterable, Codable {
    /// The person dismissed Apple's sheet.
    case cancelled
    /// Apple authorised, but returned no identity token to exchange.
    case noIdentityToken = "no_identity_token"
    /// Apple refused, or the device could not reach it.
    case authorization
    /// Apple was happy; Supabase refused the token.
    case exchange
}
