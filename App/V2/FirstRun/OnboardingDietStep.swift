import AteKit
import SwiftUI

/// **"Set your dietary requirements"** (`design/rebuild/diet.html`, Eamon's title) — straight after
/// the photo of you. The ten codes as chips in one group, diets then allergies with no gap between
/// (Eamon, 25 Oct: the split looked odd; `onboarding-diet-details.html`), any number on; a code
/// lights what it covers as well (Vegan: Vegetarian, Pescatarian, Dairy free, Egg free), faded and
/// locked. Next works once one is picked and saves them (`profiles.diet`); "None of these" moves on
/// with nothing saved. No other words.
struct OnboardingDietStep: View {
    let diet: DietStore
    /// Next (saved) or None of these.
    let onDone: () -> Void

    @State private var choice = DietChoice()
    @State private var isSaving = false
    @State private var failure: ActionFailure?
    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            AteTitle(text: OnboardingCopy.diet, style: .handleTitle)
                .padding(.horizontal, OnboardingMetrics.titleInset)
            chips(DietTag.pickingOrder)
                .padding(.horizontal, OnboardingMetrics.dietChipsInset)
                .padding(.top, OnboardingMetrics.dietTitleToChips)
            Spacer(minLength: AteMetrics.section)
            doors
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("v2.onboarding.diet")
        .ateFailureAlert($failure)
    }

    private func chips(_ tags: [DietTag]) -> some View {
        AteTogglePillFlow(spacing: AteTogglePillMetrics.largeGap, isCentred: true) {
            ForEach(tags, id: \.self) { tag in
                AteTogglePill(
                    title: tag.dietName,
                    isOn: choice.isPicked(tag),
                    isCovered: choice.isCovered(tag),
                    size: .large,
                    identifier: "onboarding.diet.\(tag.rawValue)"
                ) {
                    guard let next = choice.toggling(tag) else { return }
                    AteHaptics.key()
                    withAnimation(AteMotion.fillIn) { choice = next }
                }
            }
        }
    }

    private var doors: some View {
        VStack(spacing: AteWelcomeCardMetrics.doorsGap) {
            AteInkPill(
                title: OnboardingCopy.next,
                isEnabled: choice.isEmpty == false && isSaving == false,
                identifier: "onboarding.diet.next"
            ) {
                save()
            }
            AteWelcomeLink(title: OnboardingCopy.noneOfThese, colour: palette.fg, identifier: "onboarding.diet.none") {
                diet.declined()
                onDone()
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
    }

    /// Saved, then on. A refusal keeps the picks on screen and says so once.
    private func save() {
        isSaving = true
        let picked = choice
        Task {
            let saved = await diet.save(picked, source: .onboarding)
            isSaving = false
            if saved {
                AteHaptics.key()
                onDone()
            } else {
                failure = .diet
            }
        }
    }
}
