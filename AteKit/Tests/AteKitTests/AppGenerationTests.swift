import Foundation
import Testing

@testable import AteKit

/// **Which app the root draws** while the rebuild ships beside the current build — the flag, the
/// phone's preference, and the two rules that keep the new app away from where it must not appear.
@Suite("App generation — the current app or the rebuild")
@MainActor
struct AppGenerationTests {

    @Test("a Release build always opens the current app, whatever is set")
    func releaseNeverOpensTheNewApp() {
        for flag in [false, true] {
            for preference in [false, true] {
                #expect(AppGeneration.resolve(
                    isAvailable: false, launchFlag: flag, isUITesting: false, preference: preference
                ) == .current)
            }
        }
    }

    private func resolve(flag: Bool, testing: Bool, preference: Bool) -> AppGeneration {
        AppGeneration.resolve(isAvailable: true, launchFlag: flag, isUITesting: testing, preference: preference)
    }

    @Test("-ate-v2 opens the new app for the launch, UI test or not")
    func theFlagOpensTheNewApp() {
        #expect(resolve(flag: true, testing: false, preference: false) == .new)
        #expect(resolve(flag: true, testing: true, preference: false) == .new)
    }

    @Test("the preference decides without the flag — except in a UI-test run, which starts from nothing")
    func thePreferenceDecides() {
        #expect(resolve(flag: false, testing: false, preference: true) == .new)
        #expect(resolve(flag: false, testing: false, preference: false) == .current)
        #expect(resolve(flag: false, testing: true, preference: true) == .current)
    }

    @Test("the choice outlives the launch, and switching back forgets it")
    func thePreferencePersists() {
        let store = InMemoryKeyValueStore()
        let first = AtePreferences(store: store)
        #expect(first.opensNewApp == false, "a phone starts on the current app")
        first.opensNewApp = true
        #expect(AtePreferences(store: store).opensNewApp, "the next launch stays in the new app")
        first.opensNewApp = false
        #expect(AtePreferences(store: store).opensNewApp == false)
        #expect(store.value(forKey: "ate.opensNewApp") == nil, "switching back leaves nothing behind")
    }
}

@Suite("Shell events — the rebuilt app's tab bar")
struct ShellEventsTests {
    @Test("each event carries its name and parameters")
    func names() {
        #expect(ShellEvents.newAppOpened() == AnalyticsEvent(name: "new_app_opened"))
        #expect(ShellEvents.appSwitched(to: .new, from: .currentSettings)
            == AnalyticsEvent(name: "app_switched", parameters: ["to": "new", "source": "current_settings"]))
        #expect(ShellEvents.appSwitched(to: .current, from: .newSettings)
            == AnalyticsEvent(name: "app_switched", parameters: ["to": "current", "source": "new_settings"]))
        #expect(ShellEvents.tabSelected("feed") == AnalyticsEvent(name: "tab_selected", parameters: ["tab": "feed"]))
        #expect(ShellEvents.composeOpened(over: "journal")
            == AnalyticsEvent(name: "compose_opened", parameters: ["over": "journal"]))
    }
}
