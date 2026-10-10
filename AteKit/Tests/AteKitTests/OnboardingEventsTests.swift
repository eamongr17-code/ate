import AteKit
import Testing

@Suite("Onboarding events — the photo ask after Handle")
struct OnboardingEventsTests {
    @Test("each event carries its name and parameters")
    func names() {
        #expect(OnboardingEvents.asked() == AnalyticsEvent(name: "onboarding_asked"))
        #expect(OnboardingEvents.answered(.allowed)
            == AnalyticsEvent(name: "onboarding_answered", parameters: ["answer": "allowed"]))
        #expect(OnboardingEvents.found(meals: 14)
            == AnalyticsEvent(name: "onboarding_found", parameters: ["meals": "14"]))
        #expect(OnboardingEvents.finished(.nothingFound)
            == AnalyticsEvent(name: "onboarding_finished", parameters: ["exit": "nothing_found"]))
    }

    @Test("the photo of you, the cards and the start screen")
    func newSteps() {
        #expect(OnboardingEvents.photo(.picked)
            == AnalyticsEvent(name: "onboarding_photo", parameters: ["answer": "picked"]))
        #expect(OnboardingEvents.cards(reached: 2, skipped: true)
            == AnalyticsEvent(name: "onboarding_cards", parameters: ["card": "2", "skipped": "true"]))
        #expect(OnboardingEvents.started(.write)
            == AnalyticsEvent(name: "onboarding_start", parameters: ["start": "write"]))
    }
}
