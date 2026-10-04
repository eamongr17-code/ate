import Foundation

/// **The app's shell** — that it came up, and how people move around the tab bar. Small on purpose:
/// the flows bring their own events.
public enum ShellEvents {
    /// The new app came up — once per shell, so the count is launches spent in the rebuild.
    public static func newAppOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "new_app_opened")
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
