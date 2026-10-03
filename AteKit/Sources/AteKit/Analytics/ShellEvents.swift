import Foundation

/// **The rebuilt app's shell** (phase 2b) — which app a tester is in, and how they move around the
/// new tab bar. Small on purpose: the flows bring their own events as they land.
public enum ShellEvents {
    /// Where a switch between the two apps was made.
    public enum SwitchSource: String, Sendable {
        /// The "New app" row at the foot of the current app's Settings.
        case currentSettings = "current_settings"
        /// The way back, in the new app's own Settings.
        case newSettings = "new_settings"
    }

    /// The new app came up — once per shell, so the count is launches spent in the rebuild.
    public static func newAppOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "new_app_opened")
    }

    /// A tester moved between the current app and the rebuild.
    public static func appSwitched(to generation: AppGeneration, from source: SwitchSource) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "app_switched",
            parameters: ["to": generation == .new ? "new" : "current", "source": source.rawValue]
        )
    }

    /// A tab of the new bar was chosen. `tab` is its name (`journal`, `feed`, `search`, `you`).
    public static func tabSelected(_ tab: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "tab_selected", parameters: ["tab": tab])
    }

    /// The + tab was tapped and the composer came up over the tab it was tapped on.
    public static func composeOpened(over tab: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "compose_opened", parameters: ["over": tab])
    }
}
