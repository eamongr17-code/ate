import Foundation

/// **A write the person asked for that did not happen.** Each one is surfaced — a native alert with
/// the fewest words that say so — because a report, a block or a correction that silently did
/// nothing is the one outcome worse than an error.
///
/// Built here so the words and the event are one closed set, tested, rather than a string typed at
/// every call site.
public enum ActionFailure: String, Sendable, CaseIterable, Identifiable {
    case report
    case block
    case correctPlace = "correct_place"
    case correctDish = "correct_dish"
    case addPlace = "add_place"
    case signIn = "sign_in"
    case avatar = "avatar_upload"
    case handle = "handle_save"

    public var id: String { rawValue }

    /// The alert's title — the whole message. No second line, no "please try again" (design rule 1).
    public var title: String {
        switch self {
        case .report: "Couldn't send the report."
        case .block: "Couldn't block them."
        case .correctPlace: "Couldn't change the place."
        case .correctDish: "Couldn't change the dish."
        case .addPlace: "Couldn't add the place."
        case .signIn: "Couldn't sign in."
        case .avatar: "Couldn't change your photo."
        case .handle: "Couldn't save your handle."
        }
    }
}

/// Which detail page could not reach Ate.
public enum DetailSurface: String, Sendable, CaseIterable {
    case place
    case dish
}

/// **Failures, retries and undos** — the recovery half of the funnel. Each is a moment the app let
/// somebody down or let them change their mind, and the count of each is how we find out which.
public enum RecoveryEvents {

    /// A write failed and the person was told. `action` is ``ActionFailure``'s raw value. Sign-in
    /// is also counted by ``AccountEvents/signInFailed(provider:reason:)`` with its reason.
    public static func actionFailed(_ failure: ActionFailure) -> AnalyticsEvent {
        AnalyticsEvent(name: "action_failed", parameters: ["action": failure.rawValue])
    }

    /// A place or dish page could not load its header for a reason other than the row being gone.
    public static func detailUnreachable(_ surface: DetailSurface) -> AnalyticsEvent {
        AnalyticsEvent(name: "detail_unreachable", parameters: ["surface": surface.rawValue])
    }

    /// …and "Try again" was tapped on it.
    public static func detailRetried(_ surface: DetailSurface) -> AnalyticsEvent {
        AnalyticsEvent(name: "detail_retried", parameters: ["surface": surface.rawValue])
    }

    /// Undo, on the Saved shelf, after an unsave. The unsave itself was already counted as a
    /// `save_toggled` off; this is the regret.
    public static func unsaveUndone() -> AnalyticsEvent {
        AnalyticsEvent(name: "unsave_undone")
    }
}

/// **`Suggestions`** — the photos-to-write-up funnel beyond opening the composer.
public enum SuggestionEvents {

    /// A row's X. `photos` is how many photos went with it.
    public static func dismissed(photos: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "suggestion_dismissed", parameters: ["photos": String(max(0, photos))])
    }

    /// "Allow photos", on the screen a refused permission leaves behind.
    public static func photoAccessSettingsOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_access_settings_opened")
    }
}
