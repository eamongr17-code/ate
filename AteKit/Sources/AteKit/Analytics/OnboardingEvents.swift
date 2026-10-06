import Foundation

/// **The onboarding after Handle** (`design/rebuild/first-run.html`): the photo ask, what the roll
/// gave, and how the person left it. The funnel is ask → answer → found → finished(wrote).
public enum OnboardingEvents {
    /// What the person did with the ask.
    public enum Answer: String, Sendable {
        /// Find them, and the system said yes (full or limited).
        case allowed
        /// Find them, and the system said no.
        case denied
        /// Not now.
        case skipped
    }

    /// How the onboarding ended.
    public enum Exit: String, Sendable {
        /// A meal's pen or chip: the composer opened on it.
        case wrote
        /// The close on the found meals.
        case closed
        /// Not now, or photos refused.
        case skipped
        /// Photos allowed, but no meals in the roll.
        case nothingFound = "nothing_found"
    }

    /// The ask came up.
    public static func asked() -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_asked")
    }

    public static func answered(_ answer: Answer) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_answered", parameters: ["answer": answer.rawValue])
    }

    /// The roll was read: how many sittings it held.
    public static func found(meals: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_found", parameters: ["meals": String(meals)])
    }

    public static func finished(_ exit: Exit) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_finished", parameters: ["exit": exit.rawValue])
    }
}
