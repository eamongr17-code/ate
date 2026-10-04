import AteKit
import SwiftUI

/// The words on that page.
///
/// **COPY PROPOSAL — not approved.** Drafted by engineering from `docs/PRODUCT.md` (your words are
/// saved as written and never rewritten; the sorter only adds structure; scores are never inferred;
/// places are never assumed) and from what the app and `supabase/functions/sort-entry` actually do
/// as of round 3: **the place comes from the composer's Place key, never from the model**, and
/// dictation is the phone's own speech recognition (`requiresOnDeviceRecognition` wherever the phone
/// supports it) with only the transcript sent on to the sorter. This is public-facing product copy,
/// so it is Eamon's to approve or rewrite (AGENTS.md escalation c) before it leaves internal
/// TestFlight. Three claims need checking before they ship: that the words are not used for
/// training (the provider's terms), that photos never reach the model, and that every phone we
/// support recognises speech on the device — one that cannot falls back to Apple's servers.
enum AICopy {
    static let isProposal = true

    static let paragraphs: [String] = [
        "When you finish an entry, your words are sent to Ate's server, where an AI model reads them "
            + "and works out the dishes and the score you gave each one. That's the receipt.",
        "It only adds structure. Your words are saved exactly as you wrote them, before the model "
            + "sees them, and are never rewritten.",
        "It never guesses a score you didn't give. The place isn't the model's to guess: it's the "
            + "one you pick with the Place key. Anything it gets wrong, tap it and fix it.",
        "Dictation is speech recognition on your phone. Only the words it hears are sent, the same "
            + "as words you type. Your photos stay with your entry.",
        "Your entries aren't used to train AI models."
    ]
}
