import Foundation

/// **The onboarding after Handle** (`design/rebuild/onboarding-v2.html`): the photo of you, the four
/// cards, the start screen, the photo ask, what the roll gave, and how the person left it. The funnel
/// is photo → cards → start → (answer → found) → finished(wrote).
public enum OnboardingEvents {
    /// What the person did with "Add a photo of you."
    public enum Photo: String, Sendable {
        case picked
        case skipped
    }

    /// Which way in the start screen was taken.
    public enum Start: String, Sendable {
        /// Find it in my photos.
        case photos
        /// Write one now: a blank composer.
        case write
        /// Later: the empty Journal.
        case later
    }

    /// What the person did with the ask.
    public enum Answer: String, Sendable {
        /// Find it in my photos, and the system said yes (full or limited).
        case allowed
        /// Find it in my photos, and the system said no.
        case denied
    }

    /// How the onboarding ended.
    public enum Exit: String, Sendable {
        /// A meal's pen or chip, or Write one now: the composer opened.
        case wrote
        /// The close on the found meals.
        case closed
        /// Later on the start screen, or Later after photos were refused.
        case skipped
        /// Photos allowed, no meals in the roll, then Later.
        case nothingFound = "nothing_found"
    }

    public static func photo(_ answer: Photo) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_photo", parameters: ["answer": answer.rawValue])
    }

    /// The cards were left: the furthest one seen (1–4), and whether Skip did it.
    public static func cards(reached card: Int, skipped: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_cards", parameters: ["card": String(card), "skipped": String(skipped)])
    }

    public static func started(_ start: Start) -> AnalyticsEvent {
        AnalyticsEvent(name: "onboarding_start", parameters: ["start": start.rawValue])
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
