import Foundation
import Testing

@testable import AteKit

/// **Settings** — that each row reports what is actually true, and that the two rows which end a
/// session do so in the right order.
@Suite("Settings — the nine rows")
@MainActor
struct SettingsModelTests {

    /// One model on an in-memory account, and everything a test looks at afterwards.
    struct Rig {
        let model: SettingsModel
        let account: InMemoryAccountService
        let events: EventLog
    }

    func make(
        _ account: InMemoryAccountService = InMemoryAccountService(),
        store: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        events: EventLog = EventLog()
    ) -> Rig {
        let preferences = AtePreferences(store: store)
        let model = SettingsModel(account: account, preferences: preferences, analytics: events.recorder)
        return Rig(model: model, account: account, events: events)
    }

    // MARK: - Server rows

    @Test("the handle row shows the handle the server holds, @ and all")
    func loadsTheHandle() async {
        let rig = make(
            InMemoryAccountService(profile: AccountProfile(id: UUID(), username: "eamon"))
        )
        let model = rig.model
        let events = rig.events
        #expect(model.displayHandle == nil, "nothing is drawn until the profile has landed")
        await model.loadIfNeeded()
        #expect(model.displayHandle == "@eamon")
        #expect(events.names == ["settings_viewed"])
    }

    @Test("settings_viewed is once per appearance, not once per read")
    func reportsTheViewOnce() async {
        let rig = make()
        let model = rig.model
        let events = rig.events
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        await model.reload()
        #expect(events.events(named: "settings_viewed").count == 1)
    }

    @Test("a new handle shows in the row without a second read")
    func handleChangedIsLocal() async {
        let rig = make()
        let model = rig.model
        await model.loadIfNeeded()
        model.handleChanged(to: "eamonn")
        #expect(model.displayHandle == "@eamonn")
    }

    @Test("the photo row holds the uploaded URL")
    func uploadsAnAvatar() async {
        let rig = make()
        let model = rig.model
        await model.loadIfNeeded()
        #expect(model.avatarURL == nil)
        await model.setAvatar(AvatarUpload(data: Data([0xFF, 0xD8])))
        #expect(model.avatarURL != nil)
        #expect(model.didFail == false)
    }

    @Test("a refused upload leaves the old photo and says so")
    func refusedUploadKeepsTheOldPhoto() async {
        let account = InMemoryAccountService()
        let rig = make(account)
        let model = rig.model
        account.failure = AteAPIError.notAuthenticated
        await model.setAvatar(AvatarUpload(data: Data([0xFF, 0xD8])))
        #expect(model.avatarURL == nil)
        #expect(model.didFail)
    }

    // MARK: - The preference row

    @Test("appearance persists across a launch and reports what it changed to")
    func persistsAppearance() {
        let store = InMemoryKeyValueStore()
        let rig = make(store: store)
        let model = rig.model
        let events = rig.events
        #expect(model.appearance == .system)
        model.appearance = .dark
        #expect(AtePreferences(store: store).appearance == .dark)
        #expect(events.first(named: "appearance_changed")?.parameters["appearance"] == "dark")
    }

    @Test("setting a preference to what it already is changes nothing and says nothing")
    func noEventForANonChange() {
        let rig = make()
        let model = rig.model
        let events = rig.events
        model.appearance = .system
        #expect(events.names.isEmpty)
    }

    // MARK: - Ending the session

    @Test("sign out ends the session and reports it")
    func signsOut() async {
        let rig = make()
        let model = rig.model
        let account = rig.account
        let events = rig.events
        await model.signOut()
        #expect(account.isSignedOut)
        #expect(events.names == ["signed_out"])
    }

    @Test("delete account: delete, report, THEN sign out")
    func deletesInOrder() async {
        let rig = make()
        let model = rig.model
        let account = rig.account
        let events = rig.events
        let outcome = await model.deleteAccount()
        #expect(outcome == .deleted)
        #expect(outcome.endsSession)
        #expect(account.isDeleted)
        #expect(account.isSignedOut)
        // The event has to leave while there is still a session to send it from.
        #expect(events.names == ["account_deleted"])
        #expect(events.first(named: "account_deleted")?.parameters["auth_user_deleted"] == "true")
        #expect(model.didFailToDelete == false)
    }

    @Test("a login that survived delete_account is said out loud, and still signs out")
    func halfDeletionIsAnError() async {
        let account = InMemoryAccountService()
        account.deletion = AccountDeletion(ok: true, authUserDeleted: false)
        let rig = make(account)
        let outcome = await rig.model.deleteAccount()
        #expect(outcome == .loginSurvived)
        #expect(outcome.endsSession, "the data is gone — staying in a scrubbed account helps nobody")
        #expect(account.isSignedOut)
        #expect(rig.model.didFailToDelete, "the screen has to say this was not the deletion asked for")
        #expect(rig.events.first(named: "account_deleted")?.parameters["auth_user_deleted"] == "false")
    }

    @Test("ok = false is a refusal: nothing reported, still signed in")
    func notOkIsRefused() async {
        let account = InMemoryAccountService()
        account.deletion = AccountDeletion(ok: false, authUserDeleted: false)
        let rig = make(account)
        #expect(await rig.model.deleteAccount() == .refused)
        #expect(account.isSignedOut == false)
        #expect(rig.events.names.isEmpty)
    }

    @Test("a refused deletion is not reported as one")
    func refusedDeletionIsNotReported() async {
        let account = InMemoryAccountService()
        let rig = make(account)
        let model = rig.model
        let events = rig.events
        account.failure = AteAPIError.notAuthenticated
        let outcome = await model.deleteAccount()
        #expect(outcome == .refused)
        #expect(outcome.endsSession == false)
        #expect(account.isDeleted == false)
        #expect(account.isSignedOut == false)
        #expect(model.didFail)
        #expect(model.didFailToDelete)
        #expect(events.names.contains("account_deleted") == false)
        model.acknowledgeFailure()
        #expect(model.didFailToDelete == false)
    }

    @Test("a refused photo is not a refused deletion")
    func avatarFailureIsNotADeletionFailure() async {
        let account = InMemoryAccountService()
        let rig = make(account)
        let model = rig.model
        account.failure = AteAPIError.notAuthenticated
        await model.setAvatar(AvatarUpload(data: Data([0xFF, 0xD8])))
        #expect(model.didFail)
        #expect(model.didFailToDelete == false)
    }

    @Test("coming back to the page re-reads the handle, but only once it has been read")
    func reloadsOnReturn() async {
        let account = InMemoryAccountService(profile: AccountProfile(id: UUID(), username: "eamon"))
        let rig = make(account)
        let model = rig.model
        let events = rig.events
        await model.reloadIfLoaded()
        #expect(model.displayHandle == nil, "the first appearance belongs to loadIfNeeded")
        await model.loadIfNeeded()
        try? await account.setHandle("eamonn")
        await model.reloadIfLoaded()
        #expect(model.displayHandle == "@eamonn")
        #expect(events.events(named: "settings_viewed").count == 1)
    }
}

/// The blocked list: paging, and the optimistic unblock.
@Suite("Blocked people")
@MainActor
struct BlockedPeopleStoreTests {
    func people(_ count: Int) -> [BlockedPerson] {
        (0..<count).map { index in
            BlockedPerson(
                id: UUID(),
                username: index.isMultiple(of: 2) ? "person\(index)" : nil,
                blockedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            )
        }
    }

    @Test("the list is walked in pages, newest first, with nothing repeated")
    func pagesThrough() async {
        let blocked = people(5)
        let account = InMemoryAccountService(blocked: blocked)
        let store = BlockedPeopleStore(account: account, pageSize: 2)
        await store.loadIfNeeded()
        #expect(store.people.count == 2)
        await store.loadMore()
        await store.loadMore()
        #expect(store.people.count == 5)
        #expect(Set(store.people.map(\.id)).count == 5)
        #expect(store.people.map(\.id) == blocked.map(\.id))
    }

    @Test("an account that no longer exists is a blocked account, never an invented name")
    func namesWhatItCan() async {
        let store = BlockedPeopleStore(account: InMemoryAccountService(blocked: people(2)), pageSize: 10)
        await store.loadIfNeeded()
        #expect(store.people[0].title == "@person0")
        #expect(store.people[1].title == "Blocked account")
    }

    @Test("unblocking removes the row now and reports it")
    func unblocksOptimistically() async {
        let events = EventLog()
        let account = InMemoryAccountService(blocked: people(2))
        let store = BlockedPeopleStore(account: account, analytics: events.recorder, pageSize: 10)
        await store.loadIfNeeded()
        let person = store.people[0]
        await store.unblock(person)
        #expect(store.people.count == 1)
        #expect(account.blocked.contains { $0.id == person.id } == false)
        #expect(events.names == ["user_unblocked"])
    }

    @Test("a refused unblock puts the row back where it was")
    func putsARefusedRowBack() async {
        let account = InMemoryAccountService(blocked: people(3))
        let store = BlockedPeopleStore(account: account, pageSize: 10)
        await store.loadIfNeeded()
        let person = store.people[1]
        account.failure = AteAPIError.notAuthenticated
        await store.unblock(person)
        #expect(store.people.count == 3)
        #expect(store.people[1].id == person.id)
        #expect(store.didFail)
    }

    @Test("nobody blocked is a loaded, empty list — not a failure")
    func emptyIsAState() async {
        let store = BlockedPeopleStore(account: InMemoryAccountService(blocked: []))
        await store.loadIfNeeded()
        #expect(store.isEmpty)
        #expect(store.didFail == false)
    }
}

/// The funnel's names and parameters, asserted so they cannot drift under a dashboard.
@Suite("Account events")
struct AccountEventsTests {

    @Test("sign-in carries which door it came through")
    func signInNamesItsProvider() {
        #expect(AccountEvents.signInStarted(provider: .apple).name == "sign_in_started")
        #expect(AccountEvents.signInStarted(provider: .apple).parameters == ["provider": "apple"])
        #expect(AccountEvents.signInCompleted(provider: .apple).name == "sign_in_completed")
        #expect(
            AccountEvents.signInCompleted(provider: .debugStaging).parameters
                == ["provider": "debug_staging"]
        )
    }

    @Test("a cancelled sheet is not a broken sign-in")
    func failureNamesItsReason() {
        let event = AccountEvents.signInFailed(provider: .apple, reason: .cancelled)
        #expect(event.name == "sign_in_failed")
        #expect(event.parameters == ["provider": "apple", "reason": "cancelled"])
    }

    @Test("the rest of the vocabulary")
    func theRest() {
        #expect(AccountEvents.handleSet(isFirstRun: false).parameters == ["is_first_run": "false"])
        #expect(AccountEvents.settingsViewed().name == "settings_viewed")
        #expect(AccountEvents.appearanceChanged(.light).parameters == ["appearance": "light"])
        #expect(AccountEvents.accountDeleted().name == "account_deleted")
        #expect(AccountEvents.accountDeleted(authUserDeleted: false).parameters == ["auth_user_deleted": "false"])
        #expect(AccountEvents.userUnblocked().name == "user_unblocked")
        #expect(AccountEvents.signedOut().name == "signed_out")
    }

    @Test("every event name is snake_case, like the rest of the funnel")
    func namesMatchTheHouseStyle() {
        let events = [
            AccountEvents.signInStarted(provider: .apple),
            AccountEvents.signInCompleted(provider: .apple),
            AccountEvents.signInFailed(provider: .apple, reason: .exchange),
            AccountEvents.browseStarted(),
            AccountEvents.signInPrompted(trigger: .save),
            AccountEvents.handleSet(isFirstRun: true),
            AccountEvents.settingsViewed(),
            AccountEvents.appearanceChanged(.dark),
            AccountEvents.userUnblocked(),
            AccountEvents.signedOut(),
            AccountEvents.accountDeleted()
        ]
        for event in events {
            #expect(event.name == event.name.lowercased())
            #expect(event.name.contains(" ") == false)
            #expect(event.name.contains("-") == false)
        }
    }
}

/// The appearance preference is the only thing in the app that decides which palette is painted, so
/// it has to survive a launch and never silently reset.
@Suite("Preferences")
@MainActor
struct AtePreferencesTests {

    @Test("an empty store is System, and nobody owing a handle")
    func defaults() {
        let preferences = AtePreferences(store: InMemoryKeyValueStore())
        #expect(preferences.appearance == .system)
        #expect(preferences.pendingHandleUserID == nil)
    }

    @Test("a nonsense stored appearance falls back to System rather than crashing a launch")
    func toleratesRubbish() {
        let store = InMemoryKeyValueStore(["ate.appearance": "sepia"])
        #expect(AtePreferences(store: store).appearance == .system)
    }

    @Test("Continue ends first run for good: a kept placeholder never loops back to Handle")
    func firstRunIsDoneOnce() {
        let store = InMemoryKeyValueStore()
        let id = UUID()
        let preferences = AtePreferences(store: store)
        preferences.noteOwesHandle(id)
        #expect(preferences.owesHandle(signedInAs: id))
        preferences.handleChosen(by: id)
        #expect(preferences.owesHandle(signedInAs: id) == false)
        // Every later launch sees the placeholder again and notes it — and is ignored.
        let relaunched = AtePreferences(store: store)
        relaunched.noteOwesHandle(id)
        #expect(relaunched.owesHandle(signedInAs: id) == false)
        #expect(relaunched.pendingHandleUserID == nil)
    }

    @Test("a pending handle is bound to who is signed in, never to the next person")
    func owesHandleIsPerUser() {
        let preferences = AtePreferences(store: InMemoryKeyValueStore())
        let alice = UUID()
        let bob = UUID()
        preferences.noteOwesHandle(alice)
        #expect(preferences.owesHandle(signedInAs: bob) == false)
        #expect(preferences.owesHandle(signedInAs: nil) == false)
        #expect(preferences.owesHandle(signedInAs: alice))
    }

    @Test("the pending handle survives a first run that was killed on the handle screen")
    func remembersWhoOwesAHandle() {
        let store = InMemoryKeyValueStore()
        let id = UUID()
        AtePreferences(store: store).pendingHandleUserID = id
        #expect(AtePreferences(store: store).pendingHandleUserID == id)
        AtePreferences(store: store).pendingHandleUserID = nil
        #expect(AtePreferences(store: store).pendingHandleUserID == nil)
    }
}
