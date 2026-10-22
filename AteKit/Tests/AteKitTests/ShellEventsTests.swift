import AteKit
import Testing

@Suite("Shell events — the rebuilt app's tab bar")
struct ShellEventsTests {
    @Test("each event carries its name and parameters")
    func names() {
        #expect(ShellEvents.newAppOpened() == AnalyticsEvent(name: "new_app_opened"))
        #expect(ShellEvents.tabSelected("feed") == AnalyticsEvent(name: "tab_selected", parameters: ["tab": "feed"]))
        #expect(ShellEvents.composeOpened(over: "journal")
            == AnalyticsEvent(name: "compose_opened", parameters: ["over": "journal"]))
        #expect(ShellEvents.listFirstRead("journal", durationMilliseconds: 412, fromCache: true)
            == AnalyticsEvent(name: "list_first_read", parameters: [
                "list": "journal", "duration_ms": "412", "from_cache": "true"
            ]))
    }
}
