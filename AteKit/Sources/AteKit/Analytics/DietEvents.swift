import Foundation

/// **Diet** (`design/rebuild/diet.html`): what a person says they always eat, the one code they turn
/// off for a dish, and the counts behind a dish's diet pills.
public enum DietEvents {
    /// Where the diet was set.
    public enum Source: String, Sendable {
        /// The first-run step after the photo — Next, or "None of these".
        case onboarding
        /// Settings → Diet, a tap.
        case settings
    }

    /// The diet as it now stands: `codes` is the stored codes comma-joined in canonical order
    /// (`"gf,vg"`), `"none"` when empty.
    public static func set(source: Source, codes: [DietTag]) -> AnalyticsEvent {
        AnalyticsEvent(name: "diet_set", parameters: ["source": source.rawValue, "codes": joined(codes)])
    }

    /// In the composer, a lit diet code was turned off for the dish at the caret (`diet_off_tokens`).
    /// `isEdit` when it was a saved entry's line (then it is a `setTags` removal).
    public static func turnedOff(_ tag: DietTag, isEdit: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "diet_tag_turned_off", parameters: ["code": tag.rawValue, "edit": String(isEdit)])
    }

    /// …and tapped again, back on for that dish.
    public static func turnedOn(_ tag: DietTag, isEdit: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "diet_tag_turned_on", parameters: ["code": tag.rawValue, "edit": String(isEdit)])
    }

    /// A diet chip on a place's page was tapped: `on` is the state it was left in.
    public static func placeFilterToggled(_ tag: DietTag, isOn: Bool, restaurantID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "place_diet_filter_toggled", parameters: [
            "code": tag.rawValue,
            "on": String(isOn),
            "restaurant_id": restaurantID.uuidString.lowercased()
        ])
    }

    /// Where the diet counts popover opened (`diet-more.html`).
    public enum CountsSurface: String, Sendable {
        /// The "?" after a dish page's pills.
        case dish
        /// A diet pill on a place's Top Ate row.
        case place
    }

    /// The diet counts popover opened: the "?" on a dish, or a pill on a place's row (`code`, there).
    public static func countsOpened(surface: CountsSurface, code: DietTag? = nil) -> AnalyticsEvent {
        var parameters = ["surface": surface.rawValue]
        if let code { parameters["code"] = code.rawValue }
        return AnalyticsEvent(name: "diet_counts_opened", parameters: parameters)
    }

    static func joined(_ codes: [DietTag]) -> String {
        codes.isEmpty ? "none" : codes.map(\.rawValue).joined(separator: ",")
    }
}
