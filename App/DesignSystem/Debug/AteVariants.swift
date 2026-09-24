#if DEBUG || BETA
import Foundation
import Observation

/// **Two working answers to one uncertain interaction, both shipped, decided on-device.**
///
/// AGENTS.md: "Genuinely uncertain interactions still ship as two working variants behind a Debug
/// toggle." This is that toggle. Debug and Beta only — it reaches TestFlight, where Eamon can flip
/// it with a thumb, and it does not exist in a Release binary at all.
///
/// One preference per open question, and each one is deleted the moment it is answered. This is not
/// a settings screen in waiting.
@MainActor
@Observable
public final class AteVariants {
    public static let shared = AteVariants()

    /// **The entry page's title and bill lines.**
    ///
    /// `true` (the default) — a tap opens the place's or the dish's page, and a long press offers
    /// the correction. `false` — the artboard's original wiring: a tap opens `PlaceSheet` /
    /// `DishSheet`, and the long press offers the page.
    ///
    /// Either way both destinations are one gesture away; what is being judged is which of them
    /// owns the tap. Only meaningful on **your own** entry: somebody else's has no correction, so
    /// its lines always open the dish.
    public var entryTapOpensDetail: Bool {
        didSet { defaults.set(entryTapOpensDetail, forKey: Self.entryTapKey) }
    }

    /// `-ate-entry-tap-corrects` picks the artboard's wiring from launch, so a simulator drive can
    /// photograph either variant without a tap — the same way the gallery's own arguments work.
    static let entryTapCorrectsArgument = "-ate-entry-tap-corrects"
    private static let entryTapKey = "ate.variant.entryTapOpensDetail"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if ProcessInfo.processInfo.arguments.contains(Self.entryTapCorrectsArgument) {
            self.entryTapOpensDetail = false
        } else {
            // Absent is the default, not `false` — `bool(forKey:)` cannot tell "never set" from
            // "set to off", and the default here is on.
            self.entryTapOpensDetail = defaults.object(forKey: Self.entryTapKey) as? Bool ?? true
        }
    }

    /// What the switch is called wherever it is offered. One string, so the gallery's row and the
    /// entry page's own menu item cannot drift apart.
    public var entryTapSwitchTitle: String {
        entryTapOpensDetail ? "Tap corrects instead" : "Tap opens the page instead"
    }
}
#endif
